# encoding: UTF-8
require_relative 'public_service'
require_relative 'local_test_tables'
require_relative 'local_execution_plan_storage'
require_relative 'local_registration_time'
require_relative 'local_readiness_session'
require_relative 'coordination_request'
require_relative 'fixed_team_native_payload'

module GameRoomTournaments
  # Osobny magazyn FT1: membership i pierwszy plan zatwierdzane razem.
  class LocalFixedTeamPlanBackend
    Data = Publication::Data
    Invalid = Publication::Invalid
    A = ExecutionPlanContract
    APP = 'local-test-tournament-fixed-teams-v1'.freeze
    KIND = 'local-test-fixed-teams-v1'.freeze
    WINDOW_POLICY = 'local-test-system-window-v1'.freeze
    APPROVAL_POLICY = 'local-test-fixed-team-snapshot-approval-v1'.freeze
    attr_reader :identity

    class Unconfirmed < StandardError
      attr_reader :intent_id

      def initialize(intent_id)
        @intent_id = intent_id.dup.freeze
        super('Niepewny zapis FT1; wymagany odczyt tego samego intentu')
      end
    end

    def self.identity(directory:, source_identity:)
      directory = File.expand_path(Data.text!(directory, bytes: 4096))
      path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
      KIND + ':' + Digest::SHA256.hexdigest(JSON.generate([APP, KIND, 1, path, source_identity]))
    end

    def initialize(directory:, tables:, journal:, actor:, registry:, clock:, context: nil)
      directory = File.expand_path(Data.text!(directory, bytes: 4096)).freeze
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
      @storage = LocalExecutionPlanStorage.new(directory: File.join(directory, 'fixed-teams-v1'), guard: method(:guard!))
    end

    def local_test?
      true
    end

    def preview(publication_ref:, membership:, team_template:, base_seats:, intent_id:)
      input = detached({'publication_ref' => publication_ref, 'membership' => membership,
        'team_template' => team_template, 'base_seats' => base_seats, 'intent_id' => intent_id})
      Data.text!(input['intent_id'], bytes: 256)
      source = @service.fixed_team_execution_source(publication_ref: input['publication_ref'],
        membership: input['membership'], team_template: input['team_template'])
      candidate = source['candidate']
      policy!(candidate)
      unless candidate['roster'].size <= 256 && candidate['matches'].size.between?(1, 256) && candidate['windows'].size.between?(1, 256)
        raise Invalid, :execution_plan_limit
      end
      assignments = FixedTeamSeats.assign(candidate, input['base_seats'], members_for(source))
      body = {'version' => 1, 'identity' => identity, 'actor' => @actor, 'intent_id' => input['intent_id'], 'source' => source,
        'membership' => candidate['membership'], 'team_template' => candidate['team_template'],
        'base_seats' => input['base_seats'], 'assignments' => assignments, 'windows' => windows_for(candidate)}
      result_policy = preview_result_policy(candidate)
      body['result_policy'] = result_policy if result_policy
      detached(body.merge('digest' => digest(semantic(body))))
    end

    # Kolejność wpisana przez organizatora określa ekipę, stronę i miejsce.
    # Podgląd wszystkich przypisań poprzedza osobne accept; brak importu rosteru.
    def preview_pairs(publication_ref:, pairs:, team_template:, intent_id:)
      pairs = detached(pairs)
      unless pairs.is_a?(Array) && pairs.size.between?(2, 128) &&
          pairs.all? { |pair| pair.is_a?(Array) && pair.size == 2 }
        raise Invalid, :invalid_membership
      end
      ordered = pairs.map { |pair| pair.map { |account| Data.account(account).downcase } }
      membership = {'version' => 1, 'kind' => 'fixed-teams', 'units' => ordered.each_with_index.map do |pair, i|
        {'unit_id' => format('team-%03d', i + 1), 'accounts' => pair}
      end}
      preview_members(publication_ref: publication_ref, membership: membership, ordered: ordered,
        team_template: team_template, intent_id: intent_id)
    end

    def preview_teams(publication_ref:, teams:, team_template:, intent_id:)
      teams = detached(teams)
      unless teams.is_a?(Array) && teams.size.between?(2, 128) && teams.first.is_a?(Array) &&
          teams.first.size.between?(3, 128) && teams.all? { |team| team.is_a?(Array) && team.size == teams.first.size }
        raise Invalid, :invalid_membership
      end
      ordered = teams.map { |team| team.map { |account| Data.account(account).downcase } }
      membership = {'version' => 2, 'kind' => 'fixed-teams', 'team_size' => teams.first.size,
        'units' => ordered.each_with_index.map { |team, index| {'unit_id' => format('team-%03d', index + 1), 'accounts' => team} }}
      preview_members(publication_ref: publication_ref, membership: membership, ordered: ordered,
        team_template: team_template, intent_id: intent_id)
    end

    def preview_members(publication_ref:, membership:, ordered:, team_template:, intent_id:)
      source = @service.fixed_team_execution_source(publication_ref: publication_ref,
        membership: membership, team_template: team_template)
      candidate = source.fetch('candidate')
      policy!(candidate)
      units = membership['units'].zip(ordered).to_h { |unit, accounts| [unit['unit_id'], accounts] }
      bases = candidate['matches'].select { |match| match['leg'] == 1 }.to_h do |match|
        sides = match['unit_ids'].map { |id| units.fetch(id) }
        seats = team_template.each_with_index.map { |side, seat| sides[side][team_template.take(seat).count(side)] }
        [match['match_id'], seats]
      end
      preview(publication_ref: publication_ref, membership: membership,
        team_template: team_template, base_seats: bases, intent_id: intent_id)
    end
    private :preview_members

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
        existing = document['intents'].find { |link| link['intent_id'] == shown['intent_id'] }
        if existing
          raise Invalid, :intent_conflict unless existing['digest'] == shown['digest']
          next
        end
        prior = document['records'].find { |record| assignment_key(record['preview']).eql?(assignment_key(shown)) }
        if prior
          raise Invalid, :source_conflict unless same_assignment?(prior['preview'], shown)
        else
          prior = compile(shown)
          document['records'] << prior
        end
        document['intents'] << {'intent_id' => shown['intent_id'], 'digest' => shown['digest'],
          'record_intent_id' => prior['preview']['intent_id'], 'preview' => shown}
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

    # Katalog zwraca pierwotne rekordy po walidacji całego dokumentu; alias
    # nie tworzy drugiego planu. Odczyt nie sprawdza prawa do nowej mutacji.
    class CatalogReadError < StandardError; end

    def accepted_records(catalog: false)
      @storage.access(validate: method(:validate_document!), read_failure: catalog ? CatalogReadError : nil) do |document|
        detached(document ? document.fetch('records') : [])
      end
    end

    def current(intent_id:)
      id = Data.text!(intent_id, bytes: 256).dup.freeze
      authority!
      record = readback(intent_id: id)
      require_source!(record['preview']) if record
      record
    end

    private

    def phase_assignments(candidate, base, members)
      FixedTeamSeats.assign(candidate, base, members)
    end

    def detached(value)
      Data.freeze_tree(Data.copy(value, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16))
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(detached(value)))
    end

    def semantic(shown)
      value = Data.copy(shown, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16)
      value.delete('digest')
      value['source']['candidate'].delete('observed_at')
      value
    end

    def source_content(source)
      source.merge('candidate' => source['candidate'].reject { |key, _| key == 'observed_at' })
    end

    def require_source!(shown)
      fresh = @service.fixed_team_execution_source(publication_ref: shown['source']['candidate']['publication_ref'],
        membership: shown['membership'], team_template: shown['team_template'])
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
      raise TablesGateway::ContextChanged.new('Zmieniono lokalny kontekst FT1'), cause: error
    end

    def guard!
      unless @tables.local_test? && @tables.backend_identity.eql?(@source_identity)
        raise Invalid, :backend_changed
      end
      return unless @context
      now = @context.call
      unless now.eql?(@context_snapshot) && now['cancelled'].equal?(false) && now['account'] == @actor && now['backend_identity'] == identity
        raise Invalid, :context_changed
      end
    end

    def authority!
      raise Invalid, :context_unavailable unless @context.instance_of?(LocalReadinessSession::Context)
      guard!
    end

    def policy!(candidate)
      game = @registry.build(candidate['game_id'])
      protocol = game && game.tournament_fixed_team_protocol
      size = FixedTeamSeats.unit_size(candidate['membership'])
      count = size * 2
      supported = game && (game.tournament_fixed_team_actions? ||
        (protocol == 'card-bids-and-tricks-v1' && game.tournament_execution_kind == :turn_based &&
          size == 2 && candidate['game_options']['team_size'].eql?(2)))
      unless game && supported &&
          candidate['players_per_match'].eql?(count) &&
          game.team_size(candidate['game_options'], player_count: count).eql?(size) &&
          game.tournament_competitive_roster?(player_count: count, options: candidate['game_options'])
        raise Invalid, :unsupported_role_family
      end
      FixedTeamSeats.policy(candidate['membership'])
    end

    def preview_result_policy(candidate)
      game = @registry.build(candidate['game_id'])
      game && game.tournament_fixed_team_actions? ? GameResult::CURRENT_RESULT_POLICY : nil
    end

    def members_for(source)
      reference = source['candidate']['publication_ref']
      row = source['projection']['announcements'].find do |item|
        item['__insertion_user'].downcase == reference['author'] && item['publication_key'] == reference['publication_key']
      end
      source['projection']['members'].select { |member| member['tournament_id'] == row.fetch('__id') }
        .sort_by { |member| member['account'] }.map { |member| member.slice('account', 'username') }
    end

    def windows_for(candidate)
      policy = candidate['timezone'] == 'UTC' ? 'utc-window-v1' : WINDOW_POLICY
      candidate['windows'].map do |civil|
        opens = LocalRegistrationTime.convert_in_zone(civil['date'], civil['start'], timezone: candidate['timezone'])
        closes = LocalRegistrationTime.convert_in_zone(civil['end_date'], civil['end'], timezone: candidate['timezone'])
        {'id' => digest([policy, civil, opens, closes]), 'opens' => opens, 'closes' => closes, 'policy_ref' => policy}
      end
    end

    def execution_content(shown)
      candidate = shown['source']['candidate']
      source = candidate.slice('backend_identity', 'publication_ref', 'publication_digest', 'roster_generation', 'schedule_id',
        'source_kind', 'source_version', 'membership', 'team_template', 'roster_digest', 'pairing', 'rematch')
      source.merge!('roster' => members_for(shown['source']), 'game_id' => candidate['game_id'], 'options' => candidate['game_options'],
        'windows' => shown['windows'], 'matches' => candidate['matches'].map do |match|
          match.slice('match_id', 'leg', 'unit_ids').merge('accounts' => match['players'], 'window_ids' => shown['windows'].map { |window| window['id'] })
        end)
      source['groups'] = candidate['groups'] if candidate.key?('groups')
      source['result_policy'] = shown['result_policy'] if shown.key?('result_policy')
      scope = {'namespace' => KIND, 'app_uuid' => APP, 'backend_identity' => identity, 'tournament_id' => digest(candidate['publication_ref'])}
      {'scope' => scope, 'source' => source}
    end

    # Wyłączność turnieju nie zawiera membership/base/template ani obserwacji.
    def assignment_key(shown)
      candidate = shown['source']['candidate']
      key = [execution_content(shown)['scope'], candidate['backend_identity'], candidate['publication_ref']]
      pairs = shown['source']['projection']['pairs'] || []
      key << candidate['roster_generation'] unless pairs.empty?
      key
    end

    def same_assignment?(first, shown)
      first.values_at('actor', 'membership', 'team_template', 'base_seats', 'assignments').eql?(
        shown.values_at('actor', 'membership', 'team_template', 'base_seats', 'assignments')) && execution_content(first).eql?(execution_content(shown))
    end

    def compile(shown, ids: nil)
      candidate = shown['source']['candidate']
      ids ||= {'seal' => SecureRandom.uuid, 'plan' => SecureRandom.uuid,
        'generations' => candidate['matches'].to_h { |match| [match['match_id'], SecureRandom.uuid] }}
      scope, source = execution_content(shown).values_at('scope', 'source')
      anchor = source.slice(*A::ANCHOR).merge('source_digest' => A.digest(source))
      seal = {'id' => ids.fetch('seal'), 'revision' => '1', 'source_digest' => anchor['source_digest']}
      matches = shown['assignments'].map do |assignment|
        assignment.merge('execution_generation' => ids.fetch('generations').fetch(assignment['match_id']),
          'roles_status' => 'confirmed', 'role_policy_ref' => policy!(candidate), 'game_id' => candidate['game_id'],
          'options' => candidate['game_options'].merge('team_seats' => shown['team_template']), 'windows' => shown['windows'])
      end
      plan = {'id' => ids.fetch('plan'), 'revision' => '1', 'seal_id' => seal['id'], 'seal_revision' => seal['revision'],
        'source_digest' => anchor['source_digest'], 'approval' => {'status' => 'confirmed', 'policy_ref' => APPROVAL_POLICY}, 'matches' => matches}
      evidence = {'version' => 2, 'status' => 'confirmed', 'scope' => scope, 'source' => source, 'seal' => seal, 'plan' => plan,
        'plan_digest' => A.digest({'scope' => scope, 'plan' => plan})}
      A.validate(evidence, anchor, registry: @registry)
      request_digests, native_payload_digests = requests(evidence, anchor)
      # Cały rekord musi spełniać kontrakt readback przed dodaniem do magazynu.
      detached({'preview' => shown, 'evidence' => evidence, 'expected_source' => anchor,
        'approval' => {'actor' => shown['actor'], 'intent_id' => shown['intent_id'], 'shown_digest' => shown['digest'], 'policy_ref' => APPROVAL_POLICY},
        'request_digests' => request_digests, 'native_payload_digests' => native_payload_digests})
    end

    def requests(evidence, anchor)
      request_digests = {}
      native_digests = evidence['plan']['matches'].to_h do |match|
        windows = request_digests[match['match_id']] = {}
        [match['match_id'], match['windows'].to_h do |window|
          payload = FixedTeamNativePayload.from_execution_plan(evidence: evidence, expected_source: anchor,
            match_id: match['match_id'], leg: match['leg'], window_id: window['id'], registry: @registry)
          # Fabryka natywna już utworzyła i sprawdziła ten sam pełny request.
          windows[window['id']] = payload.to_h.fetch('request_digest')
          [window['id'], payload.digest]
        end]
      end
      [request_digests, native_digests]
    end

    def validate_preview!(shown)
      raise Invalid, :invalid_fields unless shown.is_a?(Hash)
      fields = %w[version identity actor intent_id source membership team_template base_seats assignments windows digest]
      fields += ['result_policy'] if shown.key?('result_policy')
      CoordinationRequest.fields!(shown, fields)
      CoordinationRequest.fields!(shown['source'], %w[candidate projection announcements registrations])
      Data.text!(shown['intent_id'], bytes: 256)
      Data.text!(shown['actor'], bytes: 256)
      raise Invalid, :invalid_preview unless shown['version'].eql?(1) && shown['identity'] == identity && shown['actor'] == shown['actor'].downcase
      source = shown['source']
      candidate = source['candidate']
      raise Invalid, :invalid_preview unless candidate.is_a?(Hash) && candidate['backend_identity'] == @source_identity
      projection = RegistrationProjection.build(announcements: source['announcements'], registrations: source['registrations'], registry: @registry, complete: true)
      fresh = FixedTeamScheduleCandidate.build(projection: projection, publication_ref: candidate['publication_ref'],
        backend_identity: @source_identity, observed_at: candidate['observed_at'], membership: shown['membership'], team_template: shown['team_template'])
      raise Invalid, :invalid_preview unless fresh.to_h.eql?(candidate)
      policy!(candidate)
      expected_policy = preview_result_policy(candidate)
      valid_policy = expected_policy ? GameResult::RESULT_POLICIES.include?(shown['result_policy']) : shown['result_policy'].nil?
      raise Invalid, :invalid_preview unless valid_policy
      unless projection.to_h.eql?(source['projection']) && windows_for(candidate).eql?(shown['windows']) &&
          FixedTeamSeats.assign(candidate, shown['base_seats'], members_for(source)).eql?(shown['assignments']) && digest(semantic(shown)) == shown['digest']
        raise Invalid, :invalid_preview
      end
    end

    def validate_record!(record)
      CoordinationRequest.fields!(record, %w[preview evidence expected_source approval request_digests native_payload_digests])
      validate_preview!(record['preview'])
      evidence = A.validate(record['evidence'], record['expected_source'], registry: @registry)
      ids = {'seal' => evidence['seal']['id'], 'plan' => evidence['plan']['id'],
        'generations' => evidence['plan']['matches'].to_h { |match| [match['match_id'], match['execution_generation']] }}
      [ids['seal'], ids['plan'], *ids['generations'].values].each do |id|
        raise Invalid, :sandbox_corrupt unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
      end
      unless record['preview']['actor'] == record['preview']['source']['candidate']['publication_ref']['author'] && compile(record['preview'], ids: ids).eql?(record)
        raise Invalid, :sandbox_corrupt
      end
    end

    def validate_document!(document)
      CoordinationRequest.fields!(document, %w[version identity records intents])
      unless document['version'].eql?(1) && document['identity'].eql?(identity) && document['records'].is_a?(Array) && document['intents'].is_a?(Array)
        raise Invalid, :sandbox_corrupt
      end
      records, intents = document.values_at('records', 'intents')
      limit = @phase_validation_records ? LocalExecutionPlanStorage::MAX_RECORDS : 8
      raise Invalid, :sandbox_limit if records.size > limit || intents.size > 4096
      records.each { |record| validate_record!(record) }
      ids = records.map { |record| record['preview']['intent_id'] }
      keys = records.map { |record| assignment_key(record['preview']) }
      raise Invalid, :sandbox_corrupt unless ids.uniq == ids && keys.uniq == keys
      seen = []
      intents.each do |link|
        CoordinationRequest.fields!(link, %w[intent_id digest record_intent_id preview])
        Data.text!(link['intent_id'], bytes: 256)
        raise Invalid, :sandbox_corrupt if seen.include?(link['intent_id'])
        seen << link['intent_id']
        if ids.include?(link['intent_id']) && link['record_intent_id'] != link['intent_id']
          raise Invalid, :sandbox_corrupt
        end
        record = records.find { |item| item['preview']['intent_id'] == link['record_intent_id'] }
        raise Invalid, :sandbox_corrupt unless record
        validate_preview!(link['preview'])
        unless link['preview']['intent_id'] == link['intent_id'] && link['preview']['digest'] == link['digest'] && same_assignment?(record['preview'], link['preview'])
          raise Invalid, :sandbox_corrupt
        end
        if link['intent_id'] == record['preview']['intent_id'] && !semantic(link['preview']).eql?(semantic(record['preview']))
          raise Invalid, :sandbox_corrupt
        end
      end
      raise Invalid, :sandbox_corrupt unless (ids - seen).empty?
    end
  end
end
require_relative 'local_knockout_execution_plans'
GameRoomTournaments::LocalFixedTeamPlanBackend.prepend(GameRoomTournaments::LocalKnockoutExecutionPlans)
