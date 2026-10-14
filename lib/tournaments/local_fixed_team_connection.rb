# encoding: UTF-8
require_relative 'local_fixed_team_plan_backend'
require_relative 'local_execution_plan_backend'
require_relative 'local_fixed_team_execution'
require_relative 'local_fixed_team_native_provider'

module GameRoomTournaments
  # Synchroniczny konsument wyłącznie dla Work. Nie odczytuje kontrolek.
  class LocalFixedTeamConnection
    POLICY = 'local-fixed-team-technical-trial-v1'.freeze
    def initialize(directory:, tables:, journal:, actor:, registry:, clock:, session:, program:, owner_reader:, entry:, lease:)
      @actor = Publication::Data.account(actor).downcase.freeze
      identity = backend_class.identity(directory: directory, source_identity: tables.backend_identity)
      session.bind_backend(identity)
      completed = false
      primary = nil
      begin
        @context = session.context(program: program, owner_reader: owner_reader, entry: entry, lease: lease, actor: actor, identity: identity)
        @backend = backend_class.new(directory: directory, tables: tables, journal: journal,
          actor: actor, registry: registry, clock: clock, context: @context)
        @options = {plan_backend: @backend, plan_directory: directory, source_identity: tables.backend_identity,
          context: @context, registry: registry, clock: clock, policy_ref: self.class::POLICY}
        completed = true
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        unless completed
          begin
            @context&.close(primary: primary || :throw)
          rescue Exception
            raise primary, cause: primary.cause if primary
          ensure
            raise primary, cause: primary.cause if primary
          end
        end
      end
    end

    def close(primary: nil)
      @context.close(primary: primary)
    end

    def catalog
      rows = @backend.accepted_records(catalog: true)
      own = rows.select { |r| r['evidence']['source']['roster'].any? { |person| person['account'] == @actor } ||
        r['preview']['source']['candidate']['publication_ref']['author'] == @actor }
      progress = own.to_h do |record|
        match = record['evidence']['plan']['matches'].find { |m| m['players'].any? { |p| p['account'] == @actor } } || record['evidence']['plan']['matches'].first
        execution = execution_class.new(**@options, expires_at: nil)
        execution.select_for_reconcile(intent_id: record['preview']['intent_id'], match_id: match['match_id'],
          leg: match['leg'], window_id: match['windows'].first['id'])
        [record['preview']['intent_id'], execution.progress]
      end
      {state: :read, reason: rows.empty? ? :no_accepted_plan : (own.empty? ? :no_membership : :accepted), catalog: own, progress: progress}.freeze
    rescue LocalFixedTeamPlanBackend::CatalogReadError, LocalExecutionPlanBackend::CatalogReadError, Publication::Invalid, ReadinessContract::Blocked, IOError, SystemCallError => failure
      error = [LocalFixedTeamPlanBackend::CatalogReadError, LocalExecutionPlanBackend::CatalogReadError].any? { |type| failure.is_a?(type) } ? failure.cause : failure
      reason = error.is_a?(Publication::Invalid) && error.code == :realtime_execution_required ? error.code : (error.is_a?(Publication::Invalid) ||
        (error.is_a?(ReadinessContract::Blocked) && error.code == :sandbox_corrupt) ? :sandbox_corrupt : :read_failed
      )
      {state: :read_failed, reason: reason, read_error: error}.freeze
    end

    def tournament_catalog(publication_ref:)
      rows = @backend.accepted_records(catalog: true).select do |record|
        source = record['preview']['source']['candidate']['publication_ref']
        source['author'].downcase == publication_ref.fetch('author').downcase &&
          source['publication_key'] == publication_ref.fetch('publication_key')
      end
      rows.map do |record|
        match = record['evidence']['plan']['matches'].first
        execution = execution_class.new(**@options, expires_at: nil)
        execution.select_for_reconcile(intent_id: record['preview']['intent_id'], match_id: match['match_id'],
          leg: match['leg'], window_id: match['windows'].first['id'])
        {'record' => record, 'progress' => execution.progress(public_view: true)}
      end
    end

    def plan_preview(**input)
      input.key?(:teams) ? @backend.preview_teams(**input) : @backend.preview_pairs(**input)
    end

    def plan_accept(preview:)
      @backend.accept(preview: preview)
    end

    def plan_readback(intent_id:)
      @backend.current(intent_id: intent_id)
    end

    # One bounded transition, using the same reviewed lineage and durable ports
    # as the advanced form. No background loop and no participant impersonation.
    def tournament_branch_catalog(publication_ref:, root_intents:)
      rows = tournament_catalog(publication_ref: publication_ref)
      accepted = root_intents.dup
      rows.size.times do
        rows.each do |item|
          record = item['record']
          parent = record.dig('preview', 'source', 'knockout_parent_intent')
          intent = record['preview']['intent_id']
          accepted << intent if parent && accepted.include?(parent) && !accepted.include?(intent)
        end
      end
      rows.select { |item| accepted.include?(item['record']['preview']['intent_id']) }
    end

    def advance_tournament(publication_ref:, root_intents:)
      rows = tournament_branch_catalog(publication_ref: publication_ref, root_intents: root_intents)
      parents = rows.map { |item| item['record'].dig('preview', 'source', 'knockout_parent_intent') }.compact
      leaves = rows.reject { |item| parents.include?(item['record']['preview']['intent_id']) }
      outcomes = leaves.filter_map do |item|
        record = item['record']
        candidate = record['preview']['source']['candidate']
        next unless %w[groups_knockout knockout].include?(candidate['format'])
        next unless candidate['publication_ref']['author'].downcase == @actor
        match = record['evidence']['plan']['matches'].first
        execution = execution_class.new(**@options, expires_at: nil)
        execution.select_for_reconcile(intent_id: record['preview']['intent_id'], match_id: match['match_id'],
          leg: match['leg'], window_id: match['windows'].first['id'])
        prior = execution.knockout_execution_readback
        if prior[:state] == :confirmed
          plan_dispatch_ensure_configured(intent_id: prior[:record]['preview']['intent_id'], max_tables: 3)
          next prior
        end
        preview = execution.knockout_preview
        next preview unless preview[:state] == :confirmed
        approval = execution.knockout_accept(preview: preview[:preview])
        next approval unless approval[:state] == :confirmed
        shown = execution.knockout_execution_preview
        next shown unless shown[:state] == :confirmed
        accepted = execution.knockout_execution_accept(preview: shown[:preview])
        if accepted[:state] == :confirmed
          plan_dispatch_ensure_configured(intent_id: accepted[:record]['preview']['intent_id'], max_tables: 3)
        end
        accepted
      end
      {state: :observed, transitions: outcomes}.freeze
    end

    def perform(action:, selectors:, availability: nil, expected_revision: nil, operation_id: nil, expires_at: nil, consent_id: nil, binding_digest: nil, revision: nil, move_selection: nil, realtime_input: nil, seeds: nil, phase_preview: nil, phase_execution_preview: nil, winner: nil, reason: nil)
      execution = execution_class.new(**@options, expires_at: expires_at)
      begin
        if [:organizer_result_status, :organizer_forfeit, :reconcile_readiness, :reconcile_coordination, :history, :admission_status, :local_game_status, :local_move_status, :knockout_readback, :knockout_execution_readback].include?(action)
          execution.select_for_reconcile(**selectors)
        else
          execution.select(**selectors)
        end
      rescue Publication::Invalid => error
        raise unless error.code == :source_changed
        return {state: :read_failed, reason: error.code, read_error: error}.freeze
      end
      execution.native_provider = native_provider(execution.selection[:request].to_h)
      organizer_view = execution.selection[:request].to_h['players'].none? { |person| person['account'] == @actor } &&
        execution.selection[:record]['preview']['source']['candidate']['publication_ref']['author'] == @actor
      if organizer_view && ![:organizer_result_status, :organizer_forfeit, :inspect, :history, :knockout_preview, :knockout_accept, :knockout_readback,
          :knockout_execution_preview, :knockout_execution_accept, :knockout_execution_readback].include?(action)
        return {state: :read, reason: :not_participant, selection: selectors,
          operation: {state: :blocked, reason: :not_participant}.freeze}.freeze
      end
      effect = case action
      when :organizer_result_status then execution.organizer_result_status
      when :organizer_forfeit then execution.organizer_forfeit(operation_id: operation_id, winner: winner, reason: reason, expected_revision: expected_revision)
      when :declare then execution.declare(availability: availability, expected_revision: expected_revision)
      when :reconcile_readiness then execution.reconcile_readiness(operation_id: operation_id)
      when :request_match then execution.request_match
      when :reconcile_coordination then execution.reconcile
      when :consent, :enter, :admission_status then execution.admission(action: action, consent_id: consent_id, binding_digest: binding_digest)
      when :start_local_game, :local_game_status, :local_game_surface, :local_game_move, :local_move_status, :finalize_local_game, :local_realtime_view then
        arguments = {action: action, binding_digest: binding_digest, operation_id: operation_id, revision: revision, move_selection: move_selection}
        arguments[:realtime_input] = realtime_input if realtime_input
        execution.local_game(**arguments)
      when :inspect, :history then nil
      when :knockout_preview then execution.knockout_preview(seeds: seeds)
      when :knockout_accept then execution.knockout_accept(preview: phase_preview)
      when :knockout_readback then execution.knockout_readback
      when :knockout_execution_preview then execution.knockout_execution_preview
      when :knockout_execution_accept then execution.knockout_execution_accept(preview: phase_execution_preview)
      when :knockout_execution_readback then execution.knockout_execution_readback
      else raise ArgumentError, "Nieznana czynność FT2: #{action}"
      end
      result_key = [:request_match, :reconcile_coordination].include?(action) ? :coordination : :operation
      result_key = :admission if [:consent, :enter, :admission_status].include?(action)
      result_key = :local_game if [:start_local_game, :local_game_status, :local_game_move, :local_move_status, :finalize_local_game].include?(action)
      result_key = :private_surface if action == :local_game_surface
      result_key = :realtime_surface if action == :local_realtime_view
      result_key = :phase_preview if action == :knockout_preview
      result_key = :phase_approval if [:knockout_accept, :knockout_readback].include?(action)
      result_key = :phase_execution_preview if action == :knockout_execution_preview
      result_key = :phase_execution if [:knockout_execution_accept, :knockout_execution_readback].include?(action)
      if organizer_view
        return {state: :read, reason: :accepted, current: nil, records: [], selection: selectors, result_key => effect}.freeze
      end
      begin
        current = execution.current
        {state: current[:state], reason: current[:reason], current: current[:current], records: execution.history,
          selection: selectors, result_key => effect}.freeze
      rescue Exception => error
        # Potwierdzonego skutku nie cofamy z powodu późniejszego odczytu.
        raise unless effect
        value = {state: :refresh_failed, reason: :read_failed, selection: selectors, result_key => effect, refresh_error: error}
        if action == :declare && effect[:state] == :confirmed
          value[:current] = effect.fetch(:receipt).fetch('result').slice('state', 'ready_revision', 'server_time').freeze
        end
        value.freeze
      end
    end

    private
    def backend_class; LocalFixedTeamPlanBackend; end
    def execution_class; LocalFixedTeamExecution; end
    def native_provider(request); LocalFixedTeamNativeProvider.new(capacity: request['players'].size); end
  end
end

require_relative 'local_dispatch_connection'
GameRoomTournaments::LocalFixedTeamConnection.prepend(GameRoomTournaments::LocalDispatchConnection)
