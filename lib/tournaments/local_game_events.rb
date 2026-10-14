require_relative 'local_dispatch_events'
module GameRoomTournaments
  # Process-local committed changes, separated from dispatch wake-ups.
  # A signal schedules a validated read; it carries no authoritative game data.
  module LocalGameEvents
    def self.subscribe(identity, observer)
      LocalDispatchEvents.subscribe([:game, identity], observer)
    end
    def self.publish(identity)
      LocalDispatchEvents.publish([:game, identity])
    end
    class Pending
      def initialize; @lock, @dirty, @closed = Mutex.new, false, false; end
      def signal; @lock.synchronize { @dirty = true unless @closed }; end
      def take
        @lock.synchronize do
          value = @dirty && !@closed
          @dirty = false
          value
        end
      end
      def close; @lock.synchronize { @closed = true; @dirty = false }; end
    end
  end
end
