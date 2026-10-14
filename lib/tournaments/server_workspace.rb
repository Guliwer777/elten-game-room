# encoding: UTF-8
require_relative 'public_service'
require_relative 'tables_gateway'
require_relative 'operation_journal'
require_relative 'server_schedule_store'
require_relative 'server_phase_store'
require_relative 'ordinary_match_service'
require_relative 'server_readiness_service'
require_relative 'server_proposal_service'
require_relative 'tournament_lifecycle'
require_relative '../game_room_localization'
require_relative '../game_content'

module GameRoomTournaments
  # Official application storage adapter. No schema deployment or fallback.
  class ServerWorkspace
    using GameRoomLocalization::Translations
    APP_UUID = '468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80'.freeze
    IDENTITY = "elten-tournaments:#{APP_UUID}".freeze
    Data = Publication::Data
    ERRORS = [Publication::Invalid, PublicService::Error, TablesGateway::Error,
      OperationJournal::Error, ServerPlanArchive::ContextChanged, ServerPlanArchive::Unconfirmed, OrdinaryMatchService::Blocked,
      GameRoomNetworkErrors::ClockUnavailable, IOError, SystemCallError].freeze
    attr_reader :actor, :last_error, :registry

    class Provider
      def initialize(app_uuid: APP_UUID)
        @app_uuid=app_uuid
        @client = EltenLink::Client.new
      end
      def available?; true; end
      def fetch(name)
        raise ArgumentError, 'Not a tournament table' unless (TablesGateway::TABLES + ['tournament_plan_documents']).include?(name)
        EltenLink::Apps.table(@client, @app_uuid, name)
      end
    end

    def initialize(program:, registry:, user:, alert:, clock: -> { Time.now.to_i }, provider_factory: nil, backend_uuid: APP_UUID, backend_identity: nil,
        readiness_clock: -> {GameRoomClock.now.to_i})
      @program, @registry, @user, @alert, @clock, @provider_factory = program, registry, user, alert, clock, provider_factory
      @identity = backend_identity || "elten-tournaments:#{backend_uuid}"
      @provider_factory ||= -> { Provider.new(app_uuid: backend_uuid) }
      @actor = Data.account(user.call).dup.freeze
      @readiness_clock=readiness_clock
      @owner = @actor.downcase.freeze
      @changed = false
    end

    def experimental_ui?; false; end

    def mode_label
      GameRoomContent.utf8(_("Shared tournaments"))
    end

    def load
      access do
        data=Data.copy(@service.list,max_bytes:8_388_608,max_nodes:65_536,max_depth:12)
        data['announcements'].each do |row|
          next if @clock.call < row['registration_closes_at']
          next if @clock.call >= TournamentLifecycle.ending_at(row)
          reference={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
          reader=nil
          begin
            reader=OrdinaryMatchService.new(program:@program,registry:@registry,lobby:nil,games:nil,transport:nil,
              table:@provider.fetch('tournament_plan_documents'),journal:ordinary_journal,source:-> {server_source(reference)},user:method(:account!))
            view=reader.result_view
            row['sporting_completed']=true if view['completed']
            row['sporting_completed_at']=view['completed_at'] if view['completed_at']
          rescue Publication::Invalid=>error
            raise unless [:no_players,:too_few_players,:incomplete_pairs,:unsupported_format,:registration_open,:invalid_group_configuration].include?(error.code)
          ensure
            reader&.close
          end
        end
        Data.freeze_tree(data)
      end
    end
    # The shared pure planner uses fresh server registration evidence. This is
    # an observed candidate, not a sealed roster or permission to play.
    def schedule_candidate(publication_ref:, context: nil, lease: nil)
      guard = context && -> { context.current?(lease) }
      access(input: publication_ref, guard: guard) do |reference|
        begin
          candidate = @service.schedule_candidate(publication_ref: reference, scoped: true).to_h
          game = @registry.build(candidate.fetch('game_id'))
          if game.team_size(candidate.fetch('game_options'), player_count: candidate.fetch('players_per_match')) == 2
            next {reason: :incomplete_pairs}.freeze
          end
          candidate
        rescue Publication::Invalid => error
          raise unless [:registration_open, :no_players, :too_few_players, :too_many_players,
            :plan_too_large, :unsupported_format, :invalid_group_configuration, :unresolved_source_diagnostics, :missing_publication].include?(error.code)
          {reason: error.code}.freeze
        end
      end
    end
    def operations
      access do
        rows = @journal.list + plan_journal.list + ordinary_journal.list + readiness_journal.list + proposal_journal.list + phase_journal.list
        raise OperationJournal::Conflict, :ambiguous_operation if rows.map { |row| row['id'] }.uniq.size != rows.size
        Data.freeze_tree(rows)
      end
    end

    def ordinary_service(publication_ref:, lobby:, games:, transport:)
      access(input: publication_ref) do |reference|
        ordinary_service_on_worker(publication_ref:reference,lobby:lobby,games:games,transport:transport)
      end
    end

    # Operations reconciliation already runs on a Tasks worker; no nested task.
    def ordinary_service_on_worker(publication_ref:, lobby:, games:, transport:)
      account!
      compose
      reference=Data.freeze_tree(Data.copy(publication_ref))
      row=@service.list['announcements'].find{|item|item['__insertion_user'].downcase==reference['author'].downcase && item['publication_key']==reference['publication_key']}
      raise Publication::Invalid,:missing_publication unless row
      reference=reference.merge('author'=>row['__insertion_user']).freeze
      OrdinaryMatchService.new(program:@program,registry:@registry,lobby:lobby,games:games,transport:transport,
        table:@provider.fetch('tournament_plan_documents'),journal:ordinary_journal,
        source:-> {account!; server_source(reference)},user:method(:account!))
    end
    def shared_schedule(publication_ref:, context: nil, lease: nil)
      guard = context ? -> { context.current?(lease) } : -> { true }
      access(input: publication_ref, guard: guard) do |reference|
        begin
          source = -> { server_source(reference) }
          # Avoid even opening the plan table/journal before the deadline or
          # when registration evidence cannot produce a valid candidate.
          source.call
          journal = plan_journal
          table = @provider.fetch('tournament_plan_documents')
          account!
          ServerScheduleStore.new(table: table, journal: journal, user: method(:account!), source: source, guard: guard).synchronize
        rescue Publication::Invalid => error
          raise unless [:registration_open, :no_players, :too_few_players, :too_many_players,
            :plan_too_large, :unsupported_format, :invalid_group_configuration, :unresolved_source_diagnostics, :missing_publication, :incomplete_pairs].include?(error.code)
          {reason: error.code}.freeze
        end
      end
    end

    def shared_readiness(publication_ref:, available: nil, intent_id: nil, context: nil, lease: nil)
      guard = context ? -> {context.current?(lease)} : -> {true}
      access(input:publication_ref,guard:guard) do |reference|
        source = -> {server_source(reference)}
        source.call
        service = ServerReadinessService.new(table:@provider.fetch('tournament_plan_documents'),journal:readiness_journal,
          user:method(:account!),source:source,clock:@readiness_clock,guard:guard)
        available.nil? ? service.snapshot : service.set_available(available:available,intent_id:intent_id)
      end
    end
    def advance_phase(publication_ref:,expected_schedule_id:,context:nil,lease:nil)
      guard=context ? -> {context.current?(lease)} : -> {true}
      access(input:[publication_ref,expected_schedule_id],guard:guard) do |values|
        reference=stored_reference(values[0])
        begin
          phase_store(reference,guard).advance(expected_schedule_id:values[1])
        rescue Publication::Invalid=>error
          raise unless [:phase_results_incomplete,:group_tie_requires_resolution,:tournament_completed,:unsupported_format,:phase_changed,:not_organizer].include?(error.code)
          {reason:error.code}.freeze
        end
      end
    end
    def start_notice_source(publication_ref:)
      access(input:publication_ref) do |reference|
        start_notice_source_on_worker(publication_ref:reference)
      end
    end
    def start_notice_source_on_worker(publication_ref:)
      account!
      compose
      reference=Data.freeze_tree(Data.copy(publication_ref))
      result=@service.start_notice_source(publication_ref:stored_reference(reference))
      account!
      result
    end

    def shared_proposal(publication_ref:,match_id:,leg:,action:'read',token:nil,intent_id:nil,context:nil,lease:nil)
      raise ArgumentError,'Unknown pilot action' unless %w[read propose accept decline].include?(action)
      guard=context ? -> {context.current?(lease)} : -> {true}
      access(input:[publication_ref,match_id,leg,token,intent_id],guard:guard) do |values|
        reference,id,match_leg,expected,intent=values
        service,readiness=proposal_service(reference,guard)
        match={match_id:id,leg:match_leg}
        case action
        when 'read' then service.snapshot(**match)
        when 'propose' then service.propose(**match,intent_id:intent)
        else
          result=service.respond(**match,token:expected,accept:action=='accept',intent_id:intent)
          if action=='decline'
            # Explicit refusal disables only the refusing player's availability.
            readiness.set_available(available:false,intent_id:Digest::SHA256.hexdigest('pilot-decline:'+intent))
          end
          result
        end
      end
    end
    def join(id); access(input: id) { |copy| @service.join(tournament_id: copy) }; end
    def set_partner(id, account, partner, intent)
      access(input: [id, account, partner, intent]) { |values| @service.set_partner(tournament_id: values[0], account: values[1], partner: values[2], intent_id: values[3]) }
    end
    def remove_participant(id, account)
      access(input: [id, account]) { |values| @service.remove_participant(tournament_id: values[0], account: values[1]) }
    end
    def withdraw(id); access(input: id) { |copy| @service.withdraw(tournament_id: copy) }; end
    def reconcile(id)
      access(input: id) do |copy|
        phase_record=phase_journal.fetch(copy)
        if phase_record
          document=StrictJson.parse(phase_record['values']['document_json'],max_nesting:12)
          next phase_store(stored_reference(document.fetch('publication_ref'))).reconcile(copy)
        end
        proposal_record=proposal_journal.fetch(copy)
        if proposal_record
          document=StrictJson.parse(proposal_record['values']['document_json'],max_nesting:12)
          next proposal_service(stored_reference(document.fetch('publication_ref')),-> {true}).first.reconcile(copy)
        end
        readiness_record = readiness_journal.fetch(copy)
        if readiness_record
          document=StrictJson.parse(readiness_record['values']['document_json'],max_nesting:12)
          reference=stored_reference(document.fetch('publication_ref'))
          next ServerReadinessService.new(table:@provider.fetch('tournament_plan_documents'),journal:readiness_journal,
            user:method(:account!),source:-> {server_source(reference)},clock:@readiness_clock).reconcile(copy)
        end
        ordinary_record=ordinary_journal.fetch(copy)
        if ordinary_record
          raise OrdinaryMatchService::Blocked,:match_service_unavailable unless @program.respond_to?(:reconcile_ordinary_tournament_operation)
          next @program.reconcile_ordinary_tournament_operation(ordinary_record)
        end
        plan_record = plan_journal.fetch(copy)
        if plan_record
          document = StrictJson.parse(plan_record['values']['document_json'], max_nesting: 12)
          reference = document.fetch('publication_ref')
          row = @service.list.fetch('announcements').find { |item| item['__insertion_user'].downcase == reference['author'] && item['publication_key'] == reference['publication_key'] }
          raise Publication::Invalid, :missing_publication unless row
          reference = reference.merge('author' => row['__insertion_user'])
          next ServerScheduleStore.new(table: @provider.fetch('tournament_plan_documents'), journal: plan_journal,
            user: method(:account!), source: -> { server_source(reference) }).reconcile(copy)
        end
        record = @service.reconcile(operation_id: copy)
        if record['kind'] == 'publication' && record['status'] == 'confirmed'
          record = record.merge('organizer_registration' => @service.register_creator(publication_record: record)).freeze
        end
        record
      end
    end

    def publish(**values)
      access(input: values.transform_keys(&:to_s)) do |copy|
        raise Publication::Invalid, :unsupported_withdrawal_timezone unless copy['timezone'] == 'UTC'
        publication_content!(copy)
        record = @service.publish(**copy.transform_keys(&:to_sym))
        record.merge('organizer_registration' => @service.register_creator(publication_record: record)).freeze
      end
    end

    def edit_tournament(**values)
      access(input: values.transform_keys(&:to_s)) do |copy|
        publication_content!(copy, amendment: true)
        @service.edit_tournament(**copy.transform_keys(&:to_sym))
      end
    end

    def delete_tournament(id, intent, generation)
      access(input: [id, intent, generation]) do |copy|
        @service.delete_tournament(tournament_id: copy[0], intent_id: copy[1], expected_generation: copy[2])
      end
    end

    private

    def stored_reference(reference)
      row=@service.list.fetch('announcements').find do |item|
        item['__insertion_user'].downcase==reference['author'].downcase && item['publication_key']==reference['publication_key']
      end
      raise Publication::Invalid,:missing_publication unless row
      reference.merge('author'=>row['__insertion_user'])
    end

    def proposal_journal
      account!
      @proposal_journal ||= OperationJournal.new(directory:File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16],'tournament-pilot-proposal-journals'),
        owner:@owner,backend_identity:@identity+':pilot-proposals-v1')
    end

    def proposal_service(reference,guard)
      source=-> {server_source(reference)}
      source.call
      table=@provider.fetch('tournament_plan_documents')
      readiness=ServerReadinessService.new(table:table,journal:readiness_journal,user:method(:account!),
        source:source,clock:@readiness_clock,guard:guard)
      service=ServerProposalService.new(table:table,journal:proposal_journal,user:method(:account!),
        source:source,readiness:readiness,clock:@readiness_clock,guard:guard)
      [service,readiness]
    end

    def readiness_journal
      account!
      @readiness_journal ||= OperationJournal.new(directory:File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16],'tournament-shared-readiness-journals'),
        owner:@owner,backend_identity:@identity+':shared-readiness-v1')
    end

    def ordinary_journal
      account!
      return @ordinary_journal if @ordinary_journal
      @ordinary_journal=OperationJournal.new(directory:File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16],'tournament-ordinary-match-journals'),
        owner:@owner,backend_identity:@identity+':ordinary-match-v1')
      account!
      @ordinary_journal
    end

    def server_source(reference)
      phase_store(reference).current
    end

    def phase_journal
      account!
      @phase_journal ||= OperationJournal.new(directory:File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16],'tournament-server-phase-journals'),
        owner:@owner,backend_identity:@identity+':sporting-phases-v1')
    end

    def phase_store(reference,guard=-> {true})
      table=@provider.fetch('tournament_plan_documents')
      root_source=-> {account!;@service.server_schedule_source(publication_ref:reference)}
      reader=->(candidate,root) do
        fixed=-> do
          account!
          fresh=root_source.call
          fresh=fresh.merge('candidate'=>fresh['candidate'].reject{|key,_|key=='observed_at'})
          raise Publication::Invalid,:source_changed unless fresh==root
          root.merge('candidate'=>candidate)
        end
        ordinary=OrdinaryMatchService.new(program:@program,registry:@registry,lobby:nil,games:nil,transport:nil,
          table:table,journal:ordinary_journal,source:fixed,user:method(:account!))
        begin
          ordinary.result_view
        ensure
          ordinary.close
        end
      end
      ServerPhaseStore.new(table:table,journal:phase_journal,user:method(:account!),source:root_source,results:reader,guard:guard)
    end

    def plan_journal
      account!
      return @plan_journal if @plan_journal
      directory = File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16], 'tournament-server-schedule-journals')
      account!
      @plan_journal = OperationJournal.new(directory: directory, owner: @owner, backend_identity: @identity + ':candidate-documents-v1')
      account!
      @plan_journal
    end

    def publication_content!(values, amendment: false)
      fields = %w[draft rules registration_opens_at registration_closes_at timezone]
      content = Publication.from_draft(registry: @registry, publication_key: 'server-trial-preflight',
        **values.slice(*fields).transform_keys(&:to_sym)).to_row
      limits = {'title' => 1024, 'rules' => 2048, 'settings_json' => 2048, 'schedule_json' => 2048}
      if limits.any? { |key, limit| content.fetch(key).bytesize > limit } ||
          (amendment && JSON.generate(content).bytesize + 64 > 2048)
        raise Publication::Invalid, :server_trial_payload_limit
      end
    end

    def account!
      value = Data.account(@user.call).downcase
      @changed = true unless value == @owner
      raise TablesGateway::ContextChanged, 'Account changed' if @changed
      @actor
    rescue Publication::Invalid
      @changed = true
      raise TablesGateway::ContextChanged, 'Account unavailable'
    end

    def compose
      return if @service
      account!
      provider = @provider_factory.call
      @provider = provider
      gateway = TablesGateway.new(server_tables: provider, user: method(:account!), operation_error_classes: [EltenLink::Error])
      directory = File.join(@program.data_path, 'tournaments-' + Digest::SHA256.hexdigest(@identity)[0,16], 'tournament-server-trial-journals')
      account!
      @journal = OperationJournal.new(directory: directory, owner: @owner, backend_identity: @identity)
      account!
      @service = PublicService.new(gateway: gateway, journal: @journal, registry: @registry,
        user: method(:account!), backend_identity: @identity, clock: @clock)
    end

    def access(input: nil, guard: nil)
      account!
      raise TablesGateway::Cancelled, 'View changed' if guard && !guard.call
      copy = Data.freeze_tree(Data.copy(input, max_bytes: 262_144, max_depth: 12, max_nodes: 16_384))
      result = EltenAPI::Tasks.run(title: GameRoomContent.utf8(_("Tournaments")), ui: :none, cancellable: false) do
        account!
        raise TablesGateway::Cancelled, 'View changed' if guard && !guard.call
        compose
        value = yield copy
        account!
        raise TablesGateway::Cancelled, 'View changed' if guard && !guard.call
        value
      end
      account!
      raise TablesGateway::Cancelled, 'View changed' if guard && !guard.call
      @last_error = nil
      result
    rescue *(ERRORS + (defined?(EltenLink::Error) ? [EltenLink::Error] : [])) => error
      @last_error = error
      message = if error.is_a?(Publication::Invalid) && error.code == :server_trial_payload_limit
        _("Tournament fields are limited to 2048 bytes. Shorten the rules or settings. Nothing was sent.")
      elsif error.is_a?(TablesGateway::ContextChanged) || error.is_a?(ServerPlanArchive::ContextChanged)
        _("The account changed. Close tournaments and reopen them.")
      elsif error.is_a?(TablesGateway::UnconfirmedWrite) || error.is_a?(ServerPlanArchive::Unconfirmed)
        _("Server write not confirmed. Check Operations before trying again.")
      else
        _("Tournament access failed. Check Operations before repeating a write.")
      end
      @alert.call(GameRoomContent.utf8(message))
      nil
    end
  end
end
