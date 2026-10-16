require 'thread'
module GameRoomTournaments
  # Local clients in one process only. Online clients will use authoritative
  # server change events; this is not a substitute for network presence.
  module LocalDispatchEvents
    LOCK = Mutex.new
    @listeners = {}
    class Subscription
      def initialize(identity, key); @identity, @key = identity, key; end
      def close
        LocalDispatchEvents::LOCK.synchronize do
          LocalDispatchEvents.remove(@identity, @key)
          @key = nil
        end
      end
    end
    def self.subscribe(identity, observer)
      key = Object.new
      LOCK.synchronize { (@listeners[identity] ||= {})[key] = observer }
      Subscription.new(identity, key)
    end
    def self.remove(identity, key)
      rows = @listeners[identity]
      rows&.delete(key)
      @listeners.delete(identity) if rows&.empty?
    end
    def self.publish(identity)
      observers = LOCK.synchronize { (@listeners[identity] || {}).values.dup }
      observers.each(&:signal)
    end
  end
end
