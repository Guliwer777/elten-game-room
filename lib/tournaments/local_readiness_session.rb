# encoding: UTF-8
require_relative 'entry_context'
require_relative 'readiness_contract'

module GameRoomTournaments
  # Producent KAŻDEGO jawnego wyboru testowego, bez obserwowania loginu hosta.
  class LocalReadinessSession
    class Events
      class Subscription
        def initialize(&release)
          @release = release
        end
        def close
          release, @release = @release, nil
          release&.call
        end
      end
      def initialize
        @mutex, @value, @epoch, @listeners = Mutex.new, nil, 0, {}
      end
      def snapshot
        @mutex.synchronize { {value: @value, epoch: @epoch}.freeze }
      end
      def subscribe(&callback)
        key = Object.new
        @mutex.synchronize { @listeners[key] = callback }
        Subscription.new { @mutex.synchronize { @listeners.delete(key) } }
      end
      def emit(value)
        callbacks, event = @mutex.synchronize do
          @value = value&.dup&.freeze
          @epoch += 1
          [@listeners.values, {value: @value, epoch: @epoch}.freeze]
        end
        callbacks.each { |callback| callback.call(event) }
        event
      end
      def listener_count
        @mutex.synchronize { @listeners.size }
      end
    end

    attr_reader :actor_events, :backend_events, :runtime_id
    def initialize
      @actor_events, @backend_events = Events.new, Events.new
      @runtime_id = SecureRandom.uuid.freeze
      @runtime_epoch, @closed = 1, false
      @mutex = Mutex.new
    end

    def choose_actor(actor)
      raise ReadinessContract::Blocked, :context_changed if closed?
      @actor_events.emit(Publication::Data.account(actor).downcase)
    end

    def bind_backend(identity)
      raise ReadinessContract::Blocked, :context_changed if closed?
      current = @backend_events.snapshot[:value]
      change_backend(identity) if current.nil?
      raise ReadinessContract::Blocked, :backend_changed unless @backend_events.snapshot[:value].eql?(identity)
    end

    def change_backend(identity)
      raise ReadinessContract::Blocked, :context_changed if closed?
      ReadinessContract.text!(identity)
      @backend_events.emit(identity)
    end

    def runtime_epoch
      @mutex.synchronize { @runtime_epoch }
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def close
      @mutex.synchronize do
        return if @closed
        @closed = true
        @runtime_epoch += 1
      end
      @actor_events.emit(nil)
      @backend_events.emit(nil)
      nil
    end

    def context(**options)
      Context.new(session: self, **options)
    end

    # Zdarzenie wygasza także natywne wejście, zanim worker wróci z I/O.
    class Authority < EntryContext
      def initialize(entry:, **options)
        @entry = entry
        super(**options)
      end
      def invalidate!(reason)
        super
        @entry.invalidate!(reason)
      end
    end
    private_constant :Authority

    class Context
      def initialize(session:, program:, owner_reader:, entry:, lease:, actor:, identity:)
        @session, @entry, @lease, @identity = session, entry, lease, identity
        @actor = Publication::Data.account(actor).downcase.freeze
        @actor_snapshot, @backend_snapshot = session.actor_events.snapshot, session.backend_events.snapshot
        unless @actor_snapshot[:value] == @actor && @backend_snapshot[:value] == identity
          raise ReadinessContract::Blocked, :context_changed
        end
        @authority = Authority.new(entry: entry, program: program, runtime: program.class.app_runtime,
          owner_reader: owner_reader, actor: actor, backend_identity: identity,
          account_events: session.actor_events, backend_events: session.backend_events)
        @authority_lease = @authority.capture
      end

      def call
        valid = !@session.closed? && @session.actor_events.snapshot == @actor_snapshot &&
          @session.backend_events.snapshot == @backend_snapshot && @entry.current?(@lease) && @authority.current?(@authority_lease)
        @entry.invalidate!(:sandbox_changed) unless valid
        {'account' => @actor, 'backend_identity' => @identity, 'runtime_id' => @session.runtime_id,
          'runtime_epoch' => @session.runtime_epoch, 'auth_epoch' => @session.actor_events.snapshot[:epoch],
          'backend_epoch' => @session.backend_events.snapshot[:epoch], 'cancelled' => !valid}.freeze
      end

      def close(primary: nil)
        @authority.close(primary: primary)
      end
    end
  end
end
