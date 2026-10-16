require_relative '../game_room_background'
require_relative 'local_dispatch_events'
module GameRoomTournaments
  class LocalDispatchRuntime
    attr_reader :last
    def initialize(dispatcher:, intent_id:, identity:, runtime:)
      @dispatcher, @intent = dispatcher, intent_id
      @lock, @dirty, @closed, @failed = Mutex.new, true, false, false
      @work = GameRoomBackground::Work.new(runtime: runtime)
      @subscription = LocalDispatchEvents.subscribe(identity, self)
    end
    # Commit callbacks only mark work. No I/O, forms, keyboard or retry loop.
    def signal; @lock.synchronize { @dirty = true unless @closed || @failed }; end
    def update
      return if @lock.synchronize { @closed || @failed }
      outcome = @work.take
      if outcome
        value, error = outcome
        if error
          @lock.synchronize { @failed = true }
          raise error, cause: error.cause
        end
        @last = value
        terminal = value && ((value[:state] == :blocked && [:availability_changed, :execution_interrupted].include?(value[:reason])) ||
          (value[:state] == :waiting && value[:reason] == :matches_completed))
        if terminal
          close
          return @last
        end
      end
      busy = @work.busy?
      refresh = !busy && @dispatcher.availability_refresh_due?(intent_id: @intent)
      start = @lock.synchronize do
        next false if @closed || @failed || (!@dirty && !refresh) || busy
        @dirty = false
        true
      end
      if start
        @work.start do
          renewed = refresh && @dispatcher.refresh_availability(intent_id: @intent)
          renewed && renewed[:state] != :confirmed ? renewed : @dispatcher.advance(intent_id: @intent)
        end
      end
      outcome && @last
    end
    def close
      @lock.synchronize { @closed = true }
      @subscription.close
      @work.close
    end
  end
end
