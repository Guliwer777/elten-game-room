# encoding: UTF-8
require 'securerandom'
require_relative 'publication'
require_relative 'coordination_request'

module GameRoomTournaments
  # Lokalny lease nie jest epoką uwierzytelnienia ani generacją wykonania meczu.
  class EntryContext
    Data = Publication::Data

    def initialize(program:, runtime:, owner_reader:, actor: nil, backend_identity: nil,
        account_events: nil, backend_events: nil, grant_events: nil)
      raise ArgumentError, 'Runtime nie należy do programu' unless runtime && program.class.app_runtime.equal?(runtime)
      @program, @runtime, @owner_reader = program, runtime, owner_reader
      @owner = Data.account(owner_reader.call).downcase.freeze
      @actor = actor && Data.account(actor).downcase.freeze
      @backend = backend_identity && Data.text!(backend_identity, bytes: 4096).dup.freeze
      @id, @epoch = SecureRandom.uuid.freeze, 1
      @mutex = Mutex.new
      @closed = @invalidated = false
      @sources = [account_events, backend_events, grant_events]
      @subscriptions = []
      @cleanup_attempts = [].freeze
      begin
        return unless acquire_owner(program) && acquire_owner(runtime)
        sources = @mutex.synchronize { @sources.dup }
        sources.compact.each do |source|
          return if closed?
          subscription = source.subscribe { |_event| invalidate!(:source_changed) }
          adopted = @mutex.synchronize do
            @subscriptions << subscription unless @closed
            !@closed
          end
          unless adopted
            cleanup(phase: :late_subscription) { subscription.close }
            return
          end
        end
        snapshots = sources.map { |source| source && source_snapshot(source) }
        @mutex.synchronize { @source_snapshots = snapshots unless @closed }
      rescue Exception => primary
        close(primary: primary)
        raise primary, cause: primary.cause
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end
    private :closed?

    def acquire_owner(owner)
      return false if closed?
      primary = nil
      begin
        owner.manage(self)
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        # Obcy callback może zamknąć kontekst przed dopisaniem go do Registry.
        cleanup(primary: primary, phase: :late_owner) { owner.release(self) } if closed?
      end
      !closed?
    end
    private :acquire_owner

    def capture
      @mutex.synchronize { {'entry_id' => @id, 'epoch' => @epoch}.freeze }
    end

    def current?(lease)
      program, runtime, reader = @mutex.synchronize do
        return false if @closed || @invalidated
        [@program, @runtime, @owner_reader]
      end
      account = reader.call
      owner = begin
        Data.account(account).downcase
      rescue Publication::Invalid
        nil
      end
      valid = owner == @owner && program.class.app_runtime.equal?(runtime) && Programs.runtime_registered?(runtime)
      invalidate!(:context_changed) unless valid
      @mutex.synchronize do
        !@closed && !@invalidated && lease == {'entry_id' => @id, 'epoch' => @epoch}
      end
    end

    def invalidate!(_reason)
      @mutex.synchronize do
        return if @closed
        @epoch += 1
        @invalidated = true
      end
      nil
    end

    def with_runtime(lease)
      return unless current?(lease)
      runtime = @mutex.synchronize { @runtime }
      return unless runtime
      Programs.with_runtime(runtime) { yield if current?(lease) }
    end

    # Tylko jawnie skomponowane źródła zdarzeń mogą otworzyć chroniony odczyt.
    # Domyślny Session.name nie spełnia tego kontraktu.
    def coordination_context(request:)
      return :context_unavailable unless request.instance_of?(CoordinationRequest)
      lease = capture
      sources = authority(lease)
      return :context_unavailable unless sources && request.to_h.fetch('scope').fetch('backend_identity') == @backend
      value = {'account' => @owner, 'backend_identity' => @backend, 'runtime' => @id,
        'generation' => request.to_h.fetch('execution_generation'), 'epoch' => sources[0][:epoch],
        'cancelled' => false, 'grant_epoch' => sources[2][:epoch]}
      current?(lease) ? Data.freeze_tree(Data.copy(value)) : :context_unavailable
    end

    def target_context(scope:)
      lease = capture
      return :context_unavailable unless authority(lease) && scope.is_a?(Hash) && scope['backend_identity'] == @backend
      value = {'scope' => scope, 'account' => @owner, 'runtime_id' => @id, 'epoch' => lease.fetch('epoch'), 'cancelled' => false}
      current?(lease) ? Data.freeze_tree(Data.copy(value)) : :context_unavailable
    end

    def source_snapshot(source)
      snapshot = source.snapshot
      unless snapshot.is_a?(Hash) && snapshot.keys.sort == [:epoch, :value] && Data.integer?(snapshot[:epoch], 1)
        raise ArgumentError, 'Niepełny kontrakt źródła zdarzeń'
      end
      {value: Data.freeze_tree(Data.copy(snapshot[:value])), epoch: snapshot[:epoch]}.freeze
    end
    private :source_snapshot

    def authority(lease)
      return unless current?(lease)
      sources = @mutex.synchronize { @sources.dup }
      return if sources.any?(&:nil?) || @backend.nil?
      snapshots = sources.map { |source| source_snapshot(source) }
      unless snapshots == @source_snapshots && snapshots[0][:value] == @owner && snapshots[1][:value] == @backend
        invalidate!(:source_changed)
        return nil
      end
      current?(lease) ? snapshots : nil
    end
    private :authority

    def cleanup_attempts
      @mutex.synchronize { @cleanup_attempts }
    end

    # Wyjątki przechwytujemy wyłącznie na granicy sprzątania, nie jako guard UI.
    # Jawny primary nie może pochodzić z ambient $! wywołującego.
    def cleanup(primary: nil, phase:)
      # Przechwycenie wewnątrz Fiber zachowuje jawny cause:nil. Propagacja
      # wyjątku przez resume mogłaby dopiąć obsłużony wyjątek wywołującego.
      success, value = Fiber.new do
        begin
          [true, yield]
        rescue Exception => error
          [false, error]
        end
      end.resume
      return value if success
      raise value, cause: value.cause
    rescue Exception => error
      receipt = {attempt_id: SecureRandom.uuid.freeze, phase: phase,
        failures: [{type: error.class.name.dup.freeze, message: error.message.dup.freeze,
          backtrace: error.backtrace&.map { |line| line.dup.freeze }&.freeze}.freeze].freeze}.freeze
      @mutex.synchronize { @cleanup_attempts = (@cleanup_attempts + [receipt]).freeze }
      raise error, cause: error.cause unless primary
      nil
    end

    def close(primary: nil)
      resources = @mutex.synchronize do
        return if @closed
        @closed = true
        @epoch += 1
        owners = [@program, @runtime].map { |owner| -> { owner.release(self) } }
        owners.concat(@subscriptions.map { |subscription| -> { subscription.close } })
        @program = @runtime = @owner_reader = nil
        @subscriptions, @sources, @source_snapshots = [], [], []
        owners
      end
      failure = nil
      execute_releases(resources, primary: primary, on_failure: ->(err) { failure ||= err })
      raise failure, cause: failure.cause if failure && !primary
      nil
    end

    def execute_releases(releases, index = 0, primary: nil, on_failure: nil)
      return if index >= releases.size
      begin
        cleanup(primary: primary, phase: "close:#{index}".freeze) do
          releases[index].call
        end
      rescue Exception => error
        on_failure&.call(error)
      ensure
        execute_releases(releases, index + 1, primary: primary, on_failure: on_failure)
      end
    end
    private :execute_releases
  end
end
