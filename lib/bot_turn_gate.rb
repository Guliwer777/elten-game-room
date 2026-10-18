require_relative 'server_random'

module GameRoomBots
  # Coordinates every automated seat at one table. A computer may calculate
  # and submit one action, but the next computer is not released until that
  # action has appeared in the server-confirmed event prefix. An uncertain
  # write is reconciled before a fresh decision is allowed.
  class TurnController
    Attempt = Struct.new(
      :session_id,
      :actor,
      :revision,
      :plan,
      :event_ids,
      :attempted_at,
      keyword_init: true
    )

    def initialize(
      interval: 0.0,
      verification_delay: 2.0,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @interval = interval.to_f
      @verification_delay = verification_delay.to_f
      @clock = clock
      @mutex = Mutex.new
      @state = :idle
      @lease = nil
      @attempt = nil
      @ready_at = 0.0
      @session_id = nil
      @decision_key = nil
      @decision_ready_at = 0.0
      @retired = false
    end

    def state
      @mutex.synchronize do
        advance_cooldown
        @state
      end
    end

    # Eviction and lease acquisition share this mutex. A stale reference may
    # remain in a closed screen, but can never start a second coordinator.
    def retire_if_idle
      @mutex.synchronize do
        advance_cooldown
        return false unless @state == :idle && @lease == nil
        @retired = true
      end
    end

    def switch_session(session_id)
      @mutex.synchronize do
        prepare_session(session_id)
        true
      end
    end

    def ready?(session_id:, actor:)
      @mutex.synchronize do
        return false if @retired
        prepare_session(session_id)
        advance_cooldown
        @state == :idle && @lease == nil && !actor.to_s.empty? && @clock.call >= @decision_ready_at
      end
    end

    # Called once per observed position. Reopening a form or receiving chat
    # must not restart the timer for the same pending decision.
    def schedule_decision(session_id:, actor:, revision:, delay:)
      @mutex.synchronize do
        prepare_session(session_id)
        key = [session_id.to_i, actor.to_s, normalize_revision(revision)]
        if key != @decision_key
          @decision_key = key
          @decision_ready_at = @clock.call + [delay.to_f, 0.0].max
        else
          # An approaching/corrected authoritative deadline may shorten the
          # wait. Ordinary UI refreshes must never postpone the same decision.
          @decision_ready_at = [@decision_ready_at, @clock.call + [delay.to_f, 0.0].max].min
        end
      end
    end

    def acquire(session_id:, actor:, revision:)
      @mutex.synchronize do
        return nil if @retired
        prepare_session(session_id)
        advance_cooldown
        return nil if @state != :idle || @lease != nil || actor.to_s.empty?
        return nil if @clock.call < @decision_ready_at

        @lease = Object.new
        @state = :thinking
        @attempt = Attempt.new(
          session_id: session_id.to_i,
          actor: actor.to_s,
          revision: normalize_revision(revision),
          plan: [],
          event_ids: [],
          attempted_at: nil
        )
        @lease
      end
    end

    def submitting(lease, events:)
      @mutex.synchronize do
        return false if !owned_lease?(lease) || @state != :thinking

        @attempt.plan = normalize_plan(events)
        @state = :submitting
        true
      end
    end

    def submitted(lease, event_ids:)
      @mutex.synchronize do
        return false if !owned_lease?(lease) || @state != :submitting

        @attempt.event_ids = event_ids.to_a.map(&:to_i).select { |id| id > 0 }
        begin_confirmation_wait
        true
      end
    end

    def submission_failed(lease)
      @mutex.synchronize do
        return false if !owned_lease?(lease) || ![:thinking, :submitting].include?(@state)

        begin_confirmation_wait
        true
      end
    end

    # Releases only a calculation which never entered the uncertain-write
    # phase. A screen closing while verification is pending must not make a
    # second screen repeat the old decision.
    def cancel(lease)
      @mutex.synchronize do
        return false if !owned_lease?(lease)
        return false if @state == :waiting_for_confirmation

        reset_to_idle
        true
      end
    end

    def waiting_for_confirmation?
      @mutex.synchronize { @state == :waiting_for_confirmation }
    end

    def verification_due?
      @mutex.synchronize do
        @state == :waiting_for_confirmation &&
          @attempt != nil &&
          @attempt.attempted_at != nil &&
          @clock.call >= @attempt.attempted_at + @verification_delay
      end
    end

    def defer_verification
      @mutex.synchronize do
        return false if @state != :waiting_for_confirmation || @attempt == nil

        @attempt.attempted_at = @clock.call
        true
      end
    end

    # `verified` means this snapshot came from the delayed control read, not
    # merely from the optimistic local cache. The return value is useful for
    # diagnostics; normal callers only need the updated controller state.
    def observe(session_id:, events:, confirmed_event_ids:, verified: false)
      @mutex.synchronize do
        prepare_session(session_id)
        advance_cooldown
        return :idle if @state == :idle
        return @state if @state != :waiting_for_confirmation || @attempt == nil

        confirmed = confirmed_event_ids.to_a.map(&:to_i)
        if !@attempt.event_ids.empty?
          persisted_ids = @attempt.event_ids.count { |id| confirmed.include?(id) }
          if persisted_ids > 0
            fully_confirmed = persisted_ids == @attempt.event_ids.length
            complete_attempt
            return fully_confirmed ? :confirmed : :partially_confirmed
          end
        else
          persisted = persisted_plan_prefix(events, confirmed)
          if persisted > 0
            fully_confirmed = persisted == @attempt.plan.length
            complete_attempt
            return fully_confirmed ? :confirmed : :partially_confirmed
          end
        end

        if verified
          reset_to_idle
          return :not_saved
        end

        :waiting_for_confirmation
      end
    end

    private

    def prepare_session(session_id)
      id = session_id.to_i
      if @session_id != nil && @session_id != id
        reset_to_idle
        @decision_key = nil
        @decision_ready_at = 0.0
      end

      @session_id = id
    end

    def advance_cooldown
      reset_to_idle if @state == :cooldown && @clock.call >= @ready_at
    end

    def begin_confirmation_wait
      @attempt.attempted_at = @clock.call
      @state = :waiting_for_confirmation
    end

    def complete_attempt
      @ready_at = @clock.call + @interval
      @state = :cooldown
      @lease = nil
      @attempt = nil
    end

    def reset_to_idle
      @state = :idle
      @lease = nil
      @attempt = nil
      @ready_at = 0.0
    end

    def owned_lease?(lease)
      lease != nil && @lease.equal?(lease)
    end

    def normalize_revision(revision)
      [revision.to_a[0].to_i, revision.to_a[1].to_i]
    end

    def normalize_plan(events)
      events.to_a.map do |event|
        GameRoomServerRandom.confirmation_key(event)
      end
    end

    def persisted_plan_prefix(events, confirmed_ids)
      return 0 if @attempt.plan.empty?

      base_id = @attempt.revision[1].to_i
      rows = events.to_a.select do |event|
        id = event_value(event, "__id") || event_value(event, "id")
        id = id.to_i
        id > base_id && confirmed_ids.include?(id)
      end.sort_by do |event|
        (event_value(event, "__id") || event_value(event, "id")).to_i
      end
      actor_rows = rows.select do |event|
        event_value(event, "actor").to_s.casecmp(@attempt.actor).zero?
      end

      matched = 0
      actor_rows.each do |event|
        expected = @attempt.plan[matched]
        break if expected == nil

        actual = GameRoomServerRandom.confirmation_key(event)
        break if actual != expected

        matched += 1
      end
      matched
    end

    def event_value(event, key)
      return event.public_send(key) if event.respond_to?(key)
      return nil if !event.respond_to?(:key?)
      return event[key] if event.key?(key)
      return event[key.to_sym] if event.key?(key.to_sym)

      nil
    end
  end

end
