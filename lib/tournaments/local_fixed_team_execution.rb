# encoding: UTF-8
require_relative 'local_fixed_team_readiness_port'
require_relative 'local_fixed_team_coordination_port'
require_relative 'readiness_history'
require_relative 'local_fixed_team_progress'
require_relative 'knockout_round'
require_relative 'local_knockout_plan'
require_relative 'local_game_execution_actions'
require_relative 'local_organizer_result'

module GameRoomTournaments
  # Kompozycja lokalna bez UI, zaproszeń i domyślnego endpointu hosta.
  class LocalFixedTeamExecution
    include LocalGameExecutionActions
    include LocalOrganizerResult
    Data = Publication::Data
    Invalid = Publication::Invalid
    attr_reader :selection
    attr_writer :native_provider

    def initialize(plan_backend:, plan_directory:, source_identity:, context:, registry:, clock:, policy_ref:, expires_at:)
      raise Invalid, :invalid_composition unless context.instance_of?(LocalReadinessSession::Context)
      @backend, @context, @registry, @clock = plan_backend, context, registry, clock
      @policy_ref = Data.text!(policy_ref, bytes: 256).dup.freeze
      raise Invalid, :invalid_expiry unless expires_at.nil? || Data.integer?(expires_at)
      @expires_at = expires_at
      @expected = ReadinessContract.frozen_copy(context.call)
      @storage = storage_class.new(plan_backend: plan_backend, plan_directory: plan_directory,
        source_identity: source_identity, guard: method(:guard!), registry: @registry)
      guard!
    end

    def select(**selectors)
      select_record(true, **selectors)
    end

    # Odczyt pierwotnego skutku nie nadaje prawa do nowej mutacji.
    def select_for_reconcile(**selectors)
      select_record(false, **selectors)
    end

    def select_record(fresh, intent_id:, match_id:, leg:, window_id:)
      input = Data.freeze_tree(Data.copy({'intent_id' => intent_id, 'match_id' => match_id, 'leg' => leg, 'window_id' => window_id}))
      guard!
      record = fresh ? @backend.current(intent_id: input['intent_id']) : @backend.readback(intent_id: input['intent_id'])
      raise Invalid, :missing_plan unless record
      selectors = {evidence: record['evidence'], expected_source: record['expected_source'], match_id: input['match_id'],
        leg: input['leg'], window_id: input['window_id'], registry: @registry}
      request = CoordinationRequest.from_execution_plan(**selectors)
      validate_game_execution!(request.to_h)
      native = @storage.native_payload_class.from_execution_plan(**selectors)
      unless record['request_digests'].dig(input['match_id'], input['window_id']) == request.digest &&
          @storage.bound_target_class.native_record_matches?(record, request.to_h, native)
        raise Invalid, :record_mismatch
      end
      @intent_id = input['intent_id']
      @selection = {record: record, request: request, native: native}.freeze
      @coordination_port = nil
      @port = LocalFixedTeamReadinessPort.new(storage: @storage, context: @context, record_reader: method(:record!),
        request: request, policy_ref: @policy_ref, clock: @clock)
      @readiness = ReadinessService.new(port: @port, trusted_identity: @storage.identity,
        directory: File.join(@storage.directory, 'journals'), context: @context.method(:call))
      guard!
      selection
    end

    private :select_record

    def declare(availability:, expected_revision:)
      raise Invalid, :missing_selection unless selection
      @readiness.declare(request: {'version' => 1, 'scope' => @port.scope, 'match_ref' => @port.match_ref,
        'availability' => availability, 'expected_ready_revision' => expected_revision, 'policy_ref' => @policy_ref})
    end

    def current
      raise Invalid, :missing_selection unless selection
      @readiness.current(scope: @port.scope, match_ref: @port.match_ref)
    end

    def progress(public_view: false)
      raise Invalid, :missing_selection unless selection
      record = selection[:record]
      unless public_view || record['evidence']['source']['roster'].any? { |p| p['account'] == @expected['account'] } ||
          record['preview']['source']['candidate']['publication_ref']['author'] == @expected['account']
        raise ReadinessContract::Blocked, :not_participant
      end
      now = @clock.call
      raise Invalid, :invalid_clock unless Data.integer?(now)
      @port.transaction do |document|
        progress_class.build(document: document, record: selection[:record], actor: @expected['account'],
          registry: @registry, now: now, all_matches: public_view)
      end
    end

    def knockout_preview(seeds: nil)
      raise Invalid, :missing_selection unless selection
      record!(true)
      @port.transaction do |document|
        preview = phase_preview_in(document, seeds: seeds)
        {state: :confirmed, plan: preview['plan'], preview: preview}.freeze
      end
    rescue Publication::Invalid => error
      raise unless [:group_stage_incomplete, :knockout_round_incomplete, :tournament_completed,
        :invalid_qualification_seeding, :invalid_knockout_configuration].include?(error.code)
      {state: :blocked, reason: error.code}.freeze
    end

    def knockout_accept(preview:)
      raise Invalid, :missing_selection unless selection
      shown = KnockoutPhase.frozen_copy(preview)
      KnockoutPhase.shape!(shown)
      record!(true)
      @port.transaction do |document|
        current = phase_preview_in(document, seeds: shown.fetch('plan').fetch('seeds'))
        record = knockout_store.accept(preview: shown, current: current)
        {state: :confirmed, record: record, plan: record['preview']['plan']}.freeze
      end
    rescue LocalKnockoutPlan::Unconfirmed => error
      {state: :uncertain, digest: error.digest}.freeze
    rescue Publication::Invalid => error
      raise unless [:not_author, :phase_changed, :phase_conflict, :group_stage_incomplete, :knockout_round_incomplete, :tournament_completed,
        :invalid_qualification_seeding, :invalid_knockout_configuration].include?(error.code)
      {state: :blocked, reason: error.code}.freeze
    end

    def knockout_readback
      raise Invalid, :missing_selection unless selection
      record = knockout_store.readback(parent_intent: selection[:record]['preview']['intent_id'])
      {state: record ? :confirmed : :unknown, record: record, plan: record && record['preview']['plan']}.freeze
    end

    def knockout_execution_preview
      raise Invalid, :missing_selection unless selection
      record!(true)
      @port.transaction do |document|
        approved = knockout_store.readback(parent_intent: selection[:record]['preview']['intent_id'])
        return {state: :blocked, reason: :phase_approval_required}.freeze unless approved
        fresh = phase_preview_in(document, seeds: approved['preview']['plan']['seeds'])
        raise Invalid, :phase_changed unless fresh.eql?(approved['preview'])
        shown = @backend.knockout_execution_preview(parent_intent: selection[:record]['preview']['intent_id'])
        {state: :confirmed, preview: shown}.freeze
      end
    end

    def knockout_execution_accept(preview:)
      raise Invalid, :missing_selection unless selection
      shown = KnockoutPhase.frozen_copy(preview)
      raise Invalid, :invalid_preview unless shown.is_a?(Hash) && shown['source'].is_a?(Hash)
      record!(true)
      @port.transaction do |document|
        approved = knockout_store.readback(parent_intent: selection[:record]['preview']['intent_id'])
        raise Invalid, :phase_approval_required unless approved
        fresh = phase_preview_in(document, seeds: approved['preview']['plan']['seeds'])
        raise Invalid, :phase_changed unless fresh.eql?(approved['preview']) &&
          shown.dig('source', 'knockout_parent_intent') == selection[:record]['preview']['intent_id'] &&
          shown.dig('source', 'knockout_approval').eql?(approved)
        accepted = @backend.accept(preview: shown)
        {state: :confirmed, record: accepted}.freeze
      end
    rescue LocalExecutionPlanBackend::Unconfirmed, LocalFixedTeamPlanBackend::Unconfirmed => error
      {state: :uncertain, intent_id: error.intent_id}.freeze
    end

    def knockout_execution_readback
      raise Invalid, :missing_selection unless selection
      approved = knockout_store.readback(parent_intent: selection[:record]['preview']['intent_id'])
      record = approved && @backend.readback(intent_id: 'knockout-execution-v1:' + approved['preview']['digest'])
      {state: record ? :confirmed : :unknown, record: record}.freeze
    end

    def history
      raise Invalid, :missing_selection unless selection
      ReadinessHistory.new(directory: File.join(@storage.directory, 'journals'),
        context: @context.method(:call), identity: @storage.identity).records(scope: @port.scope, match_ref: @port.match_ref)
    end

    def reconcile_readiness(operation_id:)
      raise Invalid, :missing_selection unless selection
      @readiness.reconcile(scope: @port.scope, match_ref: @port.match_ref, operation_id: operation_id)
    end

    def dispatch_invitations(renew: nil)
      raise Invalid, :missing_selection unless selection
      port = LocalDispatchInvitations.new(port: @port, storage: @storage, request: selection[:request],
        context: @context, record_reader: method(:record!), clock: @clock)
      {state: :confirmed, effect: port.send_to_available(renew: renew)}.freeze
    rescue LocalFixedTeamExecutionStorage::Unconfirmed => error
      {state: :uncertain, receipt: error.receipt}.freeze
    rescue CoordinationContract::Blocked, ReadinessContract::Blocked => error
      {state: :blocked, reason: error.code}.freeze
    end
    def admission(action:, consent_id: nil, binding_digest: nil)
      raise Invalid, :missing_selection unless selection
      port = LocalFixedTeamAdmission.new(port: @port, storage: @storage, request: selection[:request],
        context: @context, record_reader: method(:record!), clock: @clock)
      effect = case action
      when :consent then port.consent(binding_digest: binding_digest)
      when :enter then port.enter(consent_id: consent_id)
      when :admission_status then nil
      else raise ArgumentError, 'Nieznana czynność wejścia FT2'
      end
      {state: :confirmed, effect: effect, status: port.status}.freeze
    rescue LocalFixedTeamExecutionStorage::Unconfirmed => error
      {state: :uncertain, receipt: error.receipt}.freeze
    rescue CoordinationContract::Blocked, ReadinessContract::Blocked => error
      {state: :blocked, reason: error.code}.freeze
    end

    def request_match
      return {state: :blocked, reason: :technical_deadline_required, operation_id: nil, binding: nil}.freeze unless @expires_at
      raise Invalid, :missing_selection unless selection
      window = selection[:request].to_h['window']
      request = selection[:request].to_h
      people = request['players'].sort_by { |person| person['seat'] }
      seat = @registry.build(request['game_id']).tournament_table_creator_seat(options: request['options'], player_count: people.size)
      unless seat.nil?
        raise Invalid, :invalid_composition unless seat.is_a?(Integer) && seat.between?(0, people.size - 1)
        unless people.fetch(seat)['account'] == @expected['account']
          return {state: :blocked, reason: :not_coordinator, operation_id: nil, binding: nil}.freeze
        end
      end
      now = @clock.call
      unless Data.integer?(now) && window['opens'] <= now && now < @expires_at && @expires_at <= window['closes']
        return {state: :blocked, reason: :invalid_technical_deadline, operation_id: nil, binding: nil}.freeze
      end
      coordinate(:request_match)
    end

    def local_game(action:, binding_digest: nil, operation_id: nil, revision: nil, move_selection: nil, realtime_input: nil)
      raise Invalid, :missing_selection unless selection
      if GameResult::RESULT_POLICIES.include?(selection[:record].dig('evidence', 'source', 'result_policy'))
        return run_game_action(action: action, binding_digest: binding_digest, operation_id: operation_id,
          revision: revision, move_selection: move_selection, realtime_input: realtime_input)
      end
      raise Invalid, :invalid_composition if realtime_input
      port = LocalFixedTeamResult.new(port: @port, storage: @storage, request: selection[:request],
        context: @context, record_reader: method(:record!), clock: @clock, native: selection[:native], registry: @registry)
      effect = case action
      when :start_local_game then port.start(binding_digest: binding_digest)
      when :local_game_move then port.move(operation_id: operation_id, revision: revision, selection: move_selection)
      when :local_move_status then port.read_move(operation_id: operation_id)
      when :finalize_local_game then port.finalize(revision: revision)
      when :local_game_status then nil
      else raise ArgumentError, 'Nieznana czynność lokalnej partii FT2'
      end
      state = action == :local_move_status && !effect ? :unknown : :confirmed
      begin
        {state: state, effect: effect, status: port.status}.freeze
      rescue Exception => error
        raise unless effect
        {state: state, effect: effect, status: nil, refresh_error: error}.freeze
      end
    rescue LocalFixedTeamExecutionStorage::Unconfirmed => error
      {state: :uncertain, receipt: error.receipt}.freeze
    rescue CoordinationContract::Blocked, ReadinessContract::Blocked => error
      {state: :blocked, reason: error.code}.freeze
    end

    def reconcile
      coordinate(:reconcile)
    end

    def coordinator_epoch
      coordination_port.epoch
    end

    def revoke_coordinator(expected_epoch:)
      coordination_port.revoke(expected_epoch: expected_epoch)
    end

    private

    def phase_preview_in(document, seeds:)
      intent = selection[:record]['preview']['intent_id']
      receipts = document['executions'].values.select { |e| e['record_intent'] == intent && e['result'] }.map { |e| e['result'] }
      KnockoutPhase.build(record: selection[:record], receipts: receipts, seeds: seeds)
    end

    def knockout_store
      LocalKnockoutPlan.new(directory: @storage.directory, identity: @storage.identity, actor: @expected['account'],
        guard: method(:guard!), parent_reader: ->(id, fresh) { fresh ? @backend.current_for_phase_approval(intent_id: id) : @backend.readback(intent_id: id) })
    end
    def knockout_unit_count; 2; end

    def storage_class; LocalFixedTeamExecutionStorage; end
    def progress_class; LocalFixedTeamProgress; end
    def validate_game_execution!(_request); end

    def coordination_port(create: true)
      raise Invalid, :missing_selection unless selection
      @coordination_port ||= LocalFixedTeamCoordinationPort.new(readiness: @port, authority: @context, request: selection[:request],
        clock: @clock, native_provider: @native_provider, storage: @storage, record_reader: method(:record!), registry: @registry,
        policy_ref: @policy_ref, expires_at: @expires_at).preflight!.open(create: create)
    end

    def coordinate(action)
      port = begin
        record!(true) if action == :request_match
        coordination_port(create: action == :request_match)
      rescue Publication::Invalid => error
        return {state: :blocked, reason: error.code, operation_id: nil, binding: nil}.freeze
      rescue CoordinationContract::Blocked => error
        if error.code == :missing_execution && action == :reconcile
          return {state: :unknown, reason: :no_original_operation, operation_id: nil, binding: nil}.freeze
        end
        return {state: error.code == :coordination_unavailable ? :coordination_unavailable : :blocked,
          reason: error.code, operation_id: nil, binding: nil}.freeze
      end
      context = LocalFixedTeamExecutionContext.new(authority: @context, request: selection[:request], coordinator_events: port.events)
      service = CoordinationService.new(port: port, trusted_identity: @storage.identity, registry: @registry,
        directory: File.join(@storage.directory, 'journals'), context: context.method(:call))
      result = service.public_send(action, request: selection[:request])
      return result unless result[:state] == :bound
      create = result[:binding].to_h['create']
      target = port.lookup_target(operation_id: create['operation_id'], proof_ref: create['proof_ref'])
      port.validate_epoch!
      guard!
      result.merge(target: target).freeze
    rescue CoordinationContract::Blocked => error
      {state: :blocked, reason: error.code, operation_id: result && result[:operation_id], binding: nil}.freeze
    end

    private

    def record!(fresh)
      guard!
      value = fresh ? @backend.current(intent_id: @intent_id) : @backend.readback(intent_id: @intent_id)
      raise Invalid, :record_mismatch unless value.eql?(selection[:record])
      value
    end

    def guard!
      value = @context.call
      unless value.eql?(@expected) && value['cancelled'].equal?(false) && value['backend_identity'] == @backend.identity
        raise ReadinessContract::Blocked, :context_changed
      end
    end
  end
end
