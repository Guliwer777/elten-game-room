# encoding: UTF-8
require_relative 'public_service'
require_relative 'local_test_tables'
require_relative 'local_execution_plan_storage'
require_relative 'local_registration_time'
require_relative 'local_readiness_session'
require_relative 'coordination_request'
require_relative 'game_result'

module GameRoomTournaments
  # Lokalna akceptacja snapshotu, nie finalność zapisów ani uprawnienie startu.
  class LocalExecutionPlanBackend
    Data = Publication::Data
    Invalid = Publication::Invalid
    A = ExecutionPlanContract
    ROLE_POLICY = 'local-test-chess-explicit-reverse-v1'.freeze
    BOARD_ROLE_POLICY = 'local-test-board-seats-explicit-reverse-v1'.freeze
    WINDOW_POLICY = 'local-test-system-window-v1'.freeze
    APPROVAL_POLICY = 'local-test-snapshot-approval-v1'.freeze
    APP = 'local-test-tournament-execution-k02'.freeze
    attr_reader :identity
    class Unconfirmed < IOError
      attr_reader :intent_id
      def initialize(intent_id)
        @intent_id = intent_id
        super('Individual plan acceptance needs readback')
      end
    end

    def self.identity(directory:, source_identity:)
      path = File.join(File.expand_path(Data.text!(directory, bytes: 4096)), 'sandbox-k02.json')
      'local-test-k02:' + Digest::SHA256.hexdigest(JSON.generate([APP, path, source_identity]))
    end

    def initialize(directory:, tables:, journal:, actor:, registry:, clock:, context: nil)
      directory = Data.text!(directory, bytes: 4096).dup.freeze
      @actor = Data.account(actor).downcase.freeze
      unless tables.instance_of?(LocalTestTables) && tables.local_test? && journal.instance_of?(OperationJournal)
        raise Invalid, :invalid_composition
      end
      @tables, @registry, @context = tables, registry, context
      @source_identity = tables.backend_identity.dup.freeze
      unless journal.owner == @actor && journal.backend_identity == @source_identity &&
          (context.nil? || context.instance_of?(LocalReadinessSession::Context))
        raise Invalid, :invalid_composition
      end
      @identity = self.class.identity(directory: directory, source_identity: @source_identity).freeze
      @context_snapshot = context&.call
      gateway = TablesGateway.new(server_tables: tables, user: method(:gateway_actor), operation_error_classes: [LocalTestTables::Error])
      @service = PublicService.new(gateway: gateway, journal: journal, registry: registry,
        user: method(:service_actor), backend_identity: @source_identity, clock: clock)
      @storage = LocalExecutionPlanStorage.new(directory: directory, guard: method(:guard!))
    end

    def local_test?
      true
    end

    def preview(publication_ref:, base_seats:, intent_id:, result_policy: GameResult::CURRENT_RESULT_POLICY)
      input = detached({'publication_ref' => publication_ref, 'base_seats' => base_seats, 'intent_id' => intent_id})
      source = @service.execution_source(publication_ref: input['publication_ref'])
      candidate = source['candidate']
      require_competitive_roster!(candidate) unless result_policy.nil?
      unless candidate['matches'].size.between?(1, 256) && candidate['windows'].size.between?(1, 256)
        raise Invalid, :execution_plan_limit
      end
      windows = windows_for(candidate)
      assignments = TwoPlayerSeats.assign(candidate, input['base_seats'], members_for(source), registry: @registry)
      body = {'version' => 1, 'identity' => identity, 'actor' => @actor, 'intent_id' => input['intent_id'],
        'source' => source, 'base_seats' => input['base_seats'], 'assignments' => assignments, 'windows' => windows}
      body['result_policy'] = result_policy unless result_policy.nil?
      raise Invalid, :invalid_preview if body.key?('result_policy') && !GameResult::EXPORT_POLICIES.include?(result_policy)
      detached(body.merge('digest' => digest(semantic(body))))
    end

    def accept(preview:)
      shown = detached(preview)
      validate_preview!(shown)
      raise Invalid, :invalid_preview unless shown['actor'] == @actor
      authority!
      raise Invalid, :not_author unless shown['source']['candidate']['publication_ref']['author'] == @actor
      require_source!(shown)
      storage = plan_storage(shown)
      storage.access(validate: method(:validate_document!)) do |document|
        document ||= {'version' => 1, 'identity' => identity, 'records' => [], 'intents' => []}
        prior_intent = document['intents'].find { |i| i['intent_id'] == shown['intent_id'] }
        if prior_intent
          raise Invalid, :intent_conflict unless prior_intent['digest'] == shown['digest']
          next
        end
        source_key = execution_content(shown)
        prior = document['records'].find { |r| r['evidence'].slice('scope', 'source').eql?(source_key) }
        if prior
          raise Invalid, :source_conflict unless same_assignment?(prior['preview'], shown)
        else
          prior = compile(shown)
          document['records'] << prior
        end
        link = {'intent_id' => shown['intent_id'], 'digest' => shown['digest'], 'record_intent_id' => prior['preview']['intent_id']}
        # Nowy snapshot wymaga własnego dowodu, nie starego digestu rekordu.
        unless digest(semantic(prior['preview'].merge('intent_id' => shown['intent_id']))) == shown['digest']
          link['preview'] = shown
        end
        document['intents'] << link
        require_source!(shown)
        begin
          storage.write(document)
        rescue IOError, SystemCallError => error
          raise unless [:replace_attempted, :replaced].include?(storage.last_write_state)
          raise Unconfirmed.new(shown['intent_id']), cause: error
        end
      end
      require_source!(shown)
      record = readback(intent_id: shown['intent_id'])
      require_source!(shown)
      record
    end

    def readback(intent_id:)
      id = Data.text!(intent_id, bytes: 256).dup.freeze
      plan_storage_for_id(id).access(validate: method(:validate_document!)) do |document|
        link = document && document['intents'].find { |item| item['intent_id'] == id }
        record = link && document['records'].find { |item| item['preview']['intent_id'] == link['record_intent_id'] }
        record && detached(record)
      end
    end

    def current(intent_id:)
      id = Data.text!(intent_id, bytes: 256).dup.freeze
      authority!
      record = readback(intent_id: id)
      require_source!(record['preview']) if record
      record
    end

    class CatalogReadError < StandardError; end
    def accepted_records(catalog: false)
      @storage.access(validate: method(:validate_document!), read_failure: catalog ? CatalogReadError : nil) do |document|
        detached(document ? document.fetch('records') : [])
      end
    end

    private

    def phase_assignments(candidate, base, members)
      TwoPlayerSeats.assign(candidate, base, members, registry: @registry)
    end

    def detached(value)
      Data.freeze_tree(Data.copy(value, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16))
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(detached(value)))
    end

    def semantic(shown)
      copy = Data.copy(shown, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16)
      copy.delete('digest')
      copy['source']['candidate'].delete('observed_at')
      copy
    end

    def source_content(source)
      source.merge('candidate' => source['candidate'].reject { |k, _| k == 'observed_at' })
    end

    def require_source!(shown)
      fresh = @service.execution_source(publication_ref: shown['source']['candidate']['publication_ref'])
      raise Invalid, :source_changed unless source_content(fresh).eql?(source_content(shown['source']))
    end

    def service_actor
      guard!
      @actor
    rescue Invalid => error
      raise PublicService::Error.new(:account_changed), cause: error
    end

    def gateway_actor
      guard!
      @actor
    rescue Invalid => error
      raise TablesGateway::ContextChanged.new('Zmieniono lokalny kontekst K02'), cause: error
    end

    def guard!
      unless @tables.local_test? && @tables.backend_identity.eql?(@source_identity)
        raise Invalid, :backend_changed
      end
      return unless @context
      now = @context.call
      unless now.eql?(@context_snapshot) && now['cancelled'].equal?(false) &&
          now['account'] == @actor && now['backend_identity'] == identity
        raise Invalid, :context_changed
      end
    end

    def authority!
      unless @context.instance_of?(LocalReadinessSession::Context)
        raise Invalid, :context_unavailable
      end
      guard!
    end

    def members_for(source)
      reference = source['candidate']['publication_ref']
      row = source['projection']['announcements'].find do |item|
        item['__insertion_user'].downcase == reference['author'] && item['publication_key'] == reference['publication_key']
      end
      source['projection']['members'].select { |member| member['tournament_id'] == row.fetch('__id') }
        .sort_by { |member| member['account'] }
    end

    def windows_for(candidate)
      policy = candidate['timezone'] == 'UTC' ? 'utc-window-v1' : WINDOW_POLICY
      candidate['windows'].map do |civil|
        opens = LocalRegistrationTime.convert_in_zone(civil['date'], civil['start'], timezone: candidate['timezone'])
        closes = LocalRegistrationTime.convert_in_zone(civil['end_date'], civil['end'], timezone: candidate['timezone'])
        {'id' => digest([policy, civil, opens, closes]), 'opens' => opens, 'closes' => closes, 'policy_ref' => policy}
      end
    end

    # Jedna jawna obsada miejsc; nazwy kolorów dotyczą wyłącznie szachów.
    module TwoPlayerSeats
      module_function
      def policy(candidate, registry:)
        game = registry.build(candidate['game_id'])
        count = candidate['players_per_match']
        unless game && game.tournament_capabilities(options: candidate['game_options'])[:player_counts].include?(count) &&
            game.team_size(candidate['game_options'], player_count: count) == 0
          raise Invalid, :unsupported_role_family
        end
        game.tournament_role_policy(player_count: count, options: candidate['game_options'])
      end

      def assign(candidate, base, members, registry:)
        policy(candidate, registry: registry)
        count = candidate['players_per_match']
        roles = registry.build(candidate['game_id']).tournament_roles(player_count: count, options: candidate['game_options'])
        first_legs = candidate['matches'].select { |match| match['leg'] == 1 }
        unless base.is_a?(Hash) && base.keys.sort == first_legs.map { |m| m['match_id'] }.sort &&
            first_legs.all? { |m| base[m['match_id']].is_a?(Array) && base[m['match_id']].size == count &&
              base[m['match_id']].uniq.size == count && base[m['match_id']].all? { |a| a.is_a?(String) } &&
              base[m['match_id']].sort == m['players'].sort }
          raise Invalid, :invalid_base_seats
        end
        roster = members.to_h { |person| [person['account'], person.slice('account','username')] }
        candidate['matches'].map do |match|
          first = candidate['matches'].find { |m| m['leg'] == 1 && m['players'] == match['players'] }
          accounts = base.fetch(first['match_id'])
          accounts = accounts.reverse if match['leg'] == 2
          {'match_id' => match['match_id'], 'leg' => match['leg'], 'players' => accounts.each_with_index.map do |account, seat|
            roster.fetch(account).merge('seat' => seat, 'role' => 'player', 'team' => nil, 'game_role' => roles[seat])
          end, 'observers' => []}
        end
      end
    end
    private_constant :TwoPlayerSeats

    # Ten sam producent pełnego źródła A dla kompilacji i wyłączności obsady.
    # Snapshot obserwacji/freshness pozostaje szerszy i nie jest tym kluczem.
    def execution_content(shown)
      candidate = shown['source']['candidate']
      source = candidate.slice('backend_identity','publication_ref','publication_digest','roster_generation','schedule_id')
      source.merge!('roster' => members_for(shown['source']).map { |m| m.slice('account','username') },
        'game_id' => candidate['game_id'], 'options' => candidate['game_options'], 'windows' => shown['windows'],
        'matches' => candidate['matches'].map { |m| {'match_id' => m['match_id'], 'leg' => m['leg'], 'accounts' => m['players'], 'window_ids' => shown['windows'].map { |w| w['id'] }} })
      source['result_policy'] = shown['result_policy'] if shown.key?('result_policy')
      scope = {'namespace' => 'local-test-k02', 'app_uuid' => APP, 'backend_identity' => identity, 'tournament_id' => digest(candidate['publication_ref'])}
      {'scope' => scope, 'source' => source}
    end

    def same_assignment?(first, shown)
      first.values_at('actor', 'base_seats', 'assignments', 'result_policy').eql?(shown.values_at('actor', 'base_seats', 'assignments', 'result_policy'))
    end

    def compile(shown, ids: nil)
      candidate = shown['source']['candidate']
      ids ||= {'seal' => SecureRandom.uuid, 'plan' => SecureRandom.uuid,
        'generations' => candidate['matches'].to_h { |m| [m['match_id'], SecureRandom.uuid] }}
      scope, source = execution_content(shown).values_at('scope', 'source')
      anchor = source.slice(*A::ANCHOR).merge('source_digest' => A.digest(source))
      seal = {'id' => ids.fetch('seal'), 'revision' => '1', 'source_digest' => anchor['source_digest']}
      matches = shown['assignments'].map do |assignment|
        assignment.merge('execution_generation' => ids.fetch('generations').fetch(assignment['match_id']), 'roles_status' => 'confirmed', 'role_policy_ref' => TwoPlayerSeats.policy(candidate, registry: @registry),
          'game_id' => candidate['game_id'], 'options' => candidate['game_options'], 'windows' => shown['windows'])
      end
      plan = {'id' => ids.fetch('plan'), 'revision' => '1', 'seal_id' => seal['id'], 'seal_revision' => seal['revision'],
        'source_digest' => anchor['source_digest'], 'approval' => {'status' => 'confirmed', 'policy_ref' => APPROVAL_POLICY}, 'matches' => matches}
      evidence = {'version' => 1, 'status' => 'confirmed', 'scope' => scope, 'source' => source, 'seal' => seal, 'plan' => plan,
        'plan_digest' => A.digest({'scope' => scope, 'plan' => plan})}
      A.validate(evidence, anchor, registry: @registry)
      {'preview' => shown, 'evidence' => evidence, 'expected_source' => anchor,
        'approval' => {'actor' => shown['actor'], 'intent_id' => shown['intent_id'], 'shown_digest' => shown['digest'], 'policy_ref' => APPROVAL_POLICY},
        'request_digests' => requests(evidence)}
    end

    def requests(evidence)
      evidence['plan']['matches'].to_h do |match|
        [match['match_id'], match['windows'].to_h do |window|
          [window['id'], CoordinationRequest.build(A.payload(evidence, match, window), registry: @registry).digest]
        end]
      end
    end

    def validate_preview!(shown)
      fields = %w[version identity actor intent_id source base_seats assignments windows digest]
      fields += ['result_policy'] if shown.key?('result_policy')
      CoordinationRequest.fields!(shown, fields)
      raise Invalid, :invalid_preview if shown.key?('result_policy') && !GameResult::EXPORT_POLICIES.include?(shown['result_policy'])
      CoordinationRequest.fields!(shown['source'], %w[candidate projection announcements registrations])
      Data.text!(shown['intent_id'], bytes: 256)
      Data.text!(shown['actor'], bytes: 256)
      raise Invalid, :invalid_preview unless shown['version'].eql?(1) && shown['identity'] == identity && shown['actor'] == shown['actor'].downcase
      source = shown['source']
      candidate = source['candidate']
      raise Invalid, :invalid_preview unless candidate.is_a?(Hash) && candidate['backend_identity'] == @source_identity
      projection = RegistrationProjection.build(announcements: source['announcements'], registrations: source['registrations'], registry: @registry, complete: true)
      fresh = ScheduleCandidate.build(projection: projection, publication_ref: candidate['publication_ref'],
        backend_identity: @source_identity, observed_at: candidate['observed_at'])
      unless fresh.to_h.eql?(candidate) && projection.to_h.eql?(source['projection']) &&
          windows_for(candidate).eql?(shown['windows']) &&
          TwoPlayerSeats.assign(candidate, shown['base_seats'], members_for(source), registry: @registry).eql?(shown['assignments']) &&
          digest(semantic(shown)) == shown['digest']
        raise Invalid, :invalid_preview
      end
      require_competitive_roster!(candidate) if shown.key?('result_policy')
      guard!
    rescue Invalid => error
      raise Invalid.new(:invalid_preview), cause: error
    end

    def require_competitive_roster!(candidate)
      game = @registry.build(candidate['game_id'])
      unless candidate['matches'].all? { |match| game.tournament_competitive_roster?(
          player_count: match['players'].size, options: candidate['game_options']) }
        raise Invalid, :non_competing_player
      end
    end

    def validate_record!(record)
      CoordinationRequest.fields!(record, %w[preview evidence expected_source approval request_digests])
      validate_preview!(record['preview'])
      evidence = A.validate(record['evidence'], record['expected_source'], registry: @registry)
      ids = {'seal' => evidence['seal']['id'], 'plan' => evidence['plan']['id'],
        'generations' => evidence['plan']['matches'].to_h { |m| [m['match_id'], m['execution_generation']] }}
      [ids['seal'], ids['plan'], *ids['generations'].values].each do |id|
        raise Invalid, :sandbox_corrupt unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
      end
      # Odtwarzamy zależności z PIERWOTNYMI ID, bez losowania nowych generacji.
      unless record['preview']['actor'] == record['preview']['source']['candidate']['publication_ref']['author'] && compile(record['preview'], ids: ids).eql?(record)
        raise Invalid, :sandbox_corrupt
      end
    end

    def validate_intent!(link, record)
      original = record['preview']
      if link.key?('preview')
        shown = link['preview']
        validate_preview!(shown)
        unless shown['intent_id'] == link['intent_id'] && shown['digest'] == link['digest'] &&
            execution_content(shown).eql?(record['evidence'].slice('scope', 'source')) && same_assignment?(original, shown)
          raise Invalid, :sandbox_corrupt
        end
        if link['intent_id'] == original['intent_id'] && !semantic(shown).eql?(semantic(original))
          raise Invalid, :sandbox_corrupt
        end
      elsif digest(semantic(original.merge('intent_id' => link['intent_id']))) != link['digest']
        # Stare v1 bez dodatkowego dowodu są legalne tylko dla starego snapshotu.
        raise Invalid, :sandbox_corrupt
      end
    end

    def validate_document!(document)
      CoordinationRequest.fields!(document, %w[version identity records intents])
      unless document['version'].eql?(1) && document['identity'].eql?(identity) &&
          document['records'].is_a?(Array) && document['intents'].is_a?(Array)
        raise Invalid, :sandbox_corrupt
      end
      records = document['records']
      limit = @phase_validation_records ? LocalExecutionPlanStorage::MAX_RECORDS : 8
      raise Invalid, :sandbox_limit if records.size > limit || document['intents'].size > 4096
      records.each { |record| validate_record!(record) }
      ids = records.map { |r| r['preview']['intent_id'] }
      sources = records.map { |r| r['evidence'].slice('scope', 'source') }
      raise Invalid, :sandbox_corrupt unless ids.uniq == ids && sources.uniq == sources
      seen = []
      document['intents'].each do |link|
        keys = %w[intent_id digest record_intent_id]
        keys += ['preview'] if link.is_a?(Hash) && link.key?('preview')
        CoordinationRequest.fields!(link, keys)
        Data.text!(link['intent_id'], bytes: 256)
        raise Invalid, :sandbox_corrupt if seen.include?(link['intent_id'])
        seen << link['intent_id']
        # Pierwotna nazwa rekordu nie jest dowolnym aliasem innego rekordu.
        if ids.include?(link['intent_id']) && link['record_intent_id'] != link['intent_id']
          raise Invalid, :sandbox_corrupt
        end
        record = records.find { |r| r['preview']['intent_id'] == link['record_intent_id'] }
        raise Invalid, :sandbox_corrupt unless record
        validate_intent!(link, record)
      end
      raise Invalid, :sandbox_corrupt unless (ids - seen).empty?
      guard!
    rescue Invalid => error
      raise if error.code == :sandbox_limit
      raise Invalid.new(:sandbox_corrupt), cause: error
    end
  end
end
require_relative 'local_knockout_execution_plans'
GameRoomTournaments::LocalExecutionPlanBackend.prepend(GameRoomTournaments::LocalKnockoutExecutionPlans)
