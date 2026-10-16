# encoding: UTF-8
require_relative 'local_readiness_backend'
require_relative 'local_readiness_session'
require_relative 'readiness_service'
require_relative 'readiness_history'

module GameRoomTournaments
  # Synchroniczna fasada WYŁĄCZNIE dla zarządzanego workera. Nie prezentuje UI.
  class LocalReadinessConnection
    C = ReadinessContract
    def initialize(directory:, journal_directory:, actor:, clock:, source:, session:, program:, owner_reader:, entry:, lease:)
      @source = source
      backend = LocalReadinessBackend.new(directory: directory, actor: actor)
      session.bind_backend(backend.identity)
      @context = session.context(program: program, owner_reader: owner_reader, entry: entry,
        lease: lease, actor: actor, identity: backend.identity)
      begin
        @backend = LocalReadinessBackend.new(directory: directory, actor: actor, clock: clock,
          source: source, guard: method(:guard!))
        @service = ReadinessService.new(port: @backend, trusted_identity: @backend.identity,
          directory: journal_directory, context: @context.method(:call))
        @history = ReadinessHistory.new(directory: journal_directory, context: @context.method(:call), identity: @backend.identity)
        @actor = Publication::Data.account(actor).downcase.freeze
        guard!
      rescue Exception => error
        @context.close(primary: error)
        raise error, cause: error.cause
      end
    end

    def close(primary: nil)
      @context.close(primary: primary)
    end

    def perform(action:, candidate:, match_id:, prepared: nil, availability: nil, expected_revision: nil, target: nil, operation_id: nil)
      guard!
      reference = candidate && candidate.fetch('publication_ref')
      if action == :prepare
        raise C::Blocked, :missing_candidate unless reference
        fresh = fresh_candidate(reference)
        return {state: :prepared, candidate: fresh}.freeze
      end
      if action == :accept
        raise C::Blocked, :missing_candidate unless prepared.instance_of?(ScheduleCandidate)
        @backend.accept(candidate: prepared)
      end
      selected = inspect_target(candidate, match_id, target)
      return selected if [:inspect, :accept].include?(action)
      raise C::Blocked, :local_plan_required unless selected[:target]
      effect = case action
      when :declare
        # Widok historyczny nie jest zgodą na nową mutację starego planu.
        raise C::Blocked, :historical_read_only if target
        @service.declare(request: {'version' => 1, 'scope' => selected[:target][:scope],
          'match_ref' => selected[:target][:match_ref], 'availability' => availability,
          'expected_ready_revision' => expected_revision, 'policy_ref' => LocalReadinessBackend::POLICY})
      when :reconcile
        @service.reconcile(**selected[:target], operation_id: operation_id)
      else
        raise ArgumentError, "Nieznana czynność lokalnego K03: #{action}"
      end
      inspect_target(candidate, match_id, target).merge(operation: effect).freeze
    rescue C::Blocked, C::Invalid => error
      {state: :blocked, reason: error.code, current: nil, records: [].freeze, targets: [].freeze, target: nil, operation: effect}.freeze
    rescue ReadinessJournal::Busy
      {state: :blocked, reason: :local_busy, current: nil, records: [].freeze, targets: [].freeze, target: nil, operation: effect}.freeze
    rescue ReadinessJournal::Corrupt
      {state: :blocked, reason: :journal_corrupt, current: nil, records: [].freeze, targets: [].freeze, target: nil, operation: effect}.freeze
    rescue C::PortUnavailable, ReadinessJournal::Uncertain
      {state: :unknown, reason: :storage_unavailable, current: nil, records: [].freeze, targets: [].freeze, target: nil, operation: effect}.freeze
    end

    private

    def guard!
      raise C::Blocked, :context_changed if @context.call['cancelled']
    end

    def fresh_candidate(reference)
      guard!
      candidate = @source.call(reference)
      guard!
      raise C::Blocked, :missing_candidate unless candidate.instance_of?(ScheduleCandidate)
      candidate
    end

    def inspect_target(candidate, match_id, selected)
      plans = @backend.plans
      plans = plans.select { |plan| candidate.nil? || plan['candidate']['publication_ref'].eql?(candidate['publication_ref']) }
      # Lista jest pełna, również po zmianie źródła. Odczyt historii nie migruje intencji.
      targets = plans.flat_map do |plan|
        plan['candidate']['matches'].select { |match| match['players'].include?(@actor) }.map do |match|
          {plan_id: plan['plan_id'], match: match, target: {
            scope: {'app_uuid' => LocalReadinessBackend::APP, 'backend_identity' => @backend.identity,
              'tournament_id' => C.digest(plan['candidate']['publication_ref'])},
            match_ref: {'plan_id' => plan['plan_id'], 'match_id' => match['match_id'], 'leg' => match['leg'],
              'roster_generation' => plan['candidate']['roster_generation']}}}
        end
      end
      own = targets.find do |item|
        if selected
          item[:target].eql?(selected)
        else
          item[:match]['match_id'] == match_id && candidate && item[:target][:match_ref]['roster_generation'] == candidate['roster_generation']
        end
      end
      unless own
        return {state: :local_plan_required, current: nil, records: [].freeze, targets: targets.freeze, target: nil}.freeze
      end
      target = own[:target]
      current = @service.current(**target)
      records = @history.records(**target)
      {state: current[:state], reason: current[:reason], current: current[:current], target: target,
        targets: targets.freeze, records: records, plan_id: own[:plan_id]}.freeze
    end
  end
end
