# encoding: UTF-8
require_relative 'readiness_journal'
require 'securerandom'
require 'thread'

module GameRoomTournaments
  # Wyłącznie synchroniczny worker: bez UI, mowy, pętli oraz domyślnego providera.
  class ReadinessService
    C = ReadinessContract
    def initialize(port:, trusted_identity:, directory:, context:)
      C.text!(directory)
      raise C::Invalid, :invalid_directory if directory.tr('\\','/').start_with?('//') || directory.match?(/\A[A-Za-z]:(?![\\\/])/)
      @directory = File.expand_path(directory).freeze
      @port, @identity, @context = port, C.frozen_copy(trusted_identity), context
      @mutex = Mutex.new
      @diagnostics = []
    end

    def diagnostics
      C.frozen_copy(@diagnostics)
    end

    def current(scope:, match_ref:)
      run(scope, match_ref) do
        negotiate(C::READ)
        view = snapshot
        result(view['status'].to_sym, :snapshot, current:view['status']=='confirmed' ? view['current'] : nil)
      end
    end

    def declare(request:)
      data = ReadinessRequest.build(request).to_h
      run(data['scope'], data['match_ref']) do
        negotiate(C::READ)
        journal.with_attempt do |store|
          records=store.records
          previous=records.find { |r| r['operation']['request']['expected_ready_revision'].eql?(data['expected_ready_revision']) }
          if previous
            @operation=previous['operation']
            raise C::Blocked, :intent_conflict unless @operation['request'].eql?(data)
            next readback(store,@operation)
          end
          unresolved=records.find { |r| !ReadinessJournal::TERMINAL.include?(r['status']) }
          if unresolved
            @operation=unresolved['operation']
            raise C::Blocked, :unresolved_operation
          end
          negotiate(C::WRITE)
          view=snapshot
          next result(view['status'].to_sym,view['status'].to_sym) unless view['status']=='confirmed'
          C.eligible!(view,data,@expected['account'])
          @operation=C.operation(data,@expected['account'],view['accepted_match'],SecureRandom.uuid)
          C.roundtrip!(@operation,max_bytes:@byte_limit)
          store.claim(@operation)
          answer=C.response!(boundary { @port.store(operation:@operation) },@operation,max_bytes:@byte_limit)
          store.observe(@operation,answer) if ReadinessJournal::TERMINAL.include?(answer['status'])
          readback(store,@operation)
        end
      end
    rescue C::Invalid, C::Blocked => error
      {state: :blocked, reason:error.code, current:nil, receipt:nil, operation_id:nil}.freeze
    end

    def reconcile(scope:, match_ref:, operation_id:)
      key = operation_id.dup.freeze if operation_id.is_a?(String)
      run(scope,match_ref) do
        C.text!(key)
        raise C::Invalid, :invalid_operation_id unless key.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
        negotiate(C::READ)
        journal.with_attempt do |store|
          record=store.records.find { |r| r['operation']['operation_id'].eql?(key) }
          raise C::Blocked, :missing_operation unless record
          @operation=record['operation']
          readback(store,@operation)
        end
      end
    end

    private

    def journal
      ReadinessJournal.new(directory:@directory,scope:@scope,match_ref:@match_ref,account:@expected['account'],io:method(:boundary))
    end

    def readback(store, operation)
      expected = store.observed(operation)
      answer=C.response!(boundary { @port.lookup(operation:operation) },operation,max_bytes:@byte_limit)
      raise C::Blocked, :receipt_conflict if expected && !answer.eql?(expected)
      if ReadinessJournal::TERMINAL.include?(answer['status'])
        store.observe(operation,answer)
        store.resolve(operation,answer)
      end
      result(answer['status'].to_sym,:readback,receipt:answer)
    end

    def result(state, reason, current:nil, receipt:nil)
      {state:state, reason:reason, current:current, receipt:receipt, operation_id:@operation && @operation['operation_id']}.freeze
    end

    def run(scope, match_ref)
      return result(:blocked, :local_busy) unless @mutex.try_lock
      begin
        @attempt_id = SecureRandom.uuid
        @operation = nil
        return result(:unsupported, :missing_port) unless @port && %i[identity negotiate snapshot lookup store].all? { |m| @port.respond_to?(m) }
        return result(:blocked, :incomplete_context) unless @context.respond_to?(:call)
        @scope, @match_ref = C.frozen_copy(scope), C.frozen_copy(match_ref)
        C.target!(@scope, @match_ref)
        guard!
        yield
      rescue C::Blocked => error
        result(error.code==:unsupported ? :unsupported : :blocked, error.code)
      rescue ReadinessJournal::Corrupt => error
        @operation ||= error.operation
        diagnostic(error)
        result(:blocked, :journal_corrupt)
      rescue ReadinessJournal::Busy
        result(:blocked, :local_busy)
      rescue ReadinessJournal::Uncertain => error
        diagnostic(error)
        result(:unknown, :local_uncertain)
      rescue C::KnownRefused
        result(:refused, :known_refused)
      rescue C::PortUnavailable
        result(:unknown, :port_unavailable)
      rescue C::Invalid => error
        result(:blocked, error.code)
      ensure
        @mutex.unlock
      end
    end

    def guard!
      raise C::Blocked, :context_changed if @invalidated
      value = C.copy(@context.call)
      C.fields!(value, %w[account backend_identity runtime_id runtime_epoch auth_epoch backend_epoch cancelled])
      %w[account backend_identity runtime_id].each { |key| C.text!(value[key]) }
      unless %w[runtime_epoch auth_epoch backend_epoch].all? { |key| C::Data.integer?(value[key],1) } &&
          value['cancelled'].equal?(false) && value['account'].eql?(value['account'].downcase) &&
          value['backend_identity'].eql?(@identity) && @scope['backend_identity'].eql?(@identity)
        @invalidated = true
        raise C::Blocked, :incomplete_context
      end
      @expected ||= C.frozen_copy(value)
      unless value.eql?(@expected) && @port.identity.eql?(@identity)
        @invalidated = true
        raise C::Blocked, :context_changed
      end
    rescue C::Invalid
      @invalidated = true
      raise C::Blocked, :incomplete_context
    end

    def diagnostic(error)
      # Diagnostyka ma własny mały budżet, niezależny od treści wyjątku.
      text = ->(value, limit=128) { value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).byteslice(0,limit).scrub }
      entry = {'attempt_id'=>@attempt_id, 'class'=>text.call(error.class.name),
        'message'=>text.call(error.message,1024), 'backtrace'=>Array(error.backtrace).first(4).map { |line| text.call(line) }}
      @diagnostics.shift while @diagnostics.size>=4
      @diagnostics << C.frozen_copy(entry)
    end

    def boundary(cleanup:false)
      if cleanup
        primary=nil
        begin
          guard!
        rescue Exception => error
          primary=error
          diagnostic(error)
        ensure
          # Własny uchwyt zwalniamy również po nielokalnym wyjściu z guardu.
          begin
            yield
          rescue Exception => error
            primary ||= error
            diagnostic(error)
          ensure
            begin
              guard!
            rescue Exception => error
              primary ||= error
              diagnostic(error)
            ensure
              raise primary, cause:primary.cause if primary
            end
          end
        end
        return
      end
      guard!
      primary = nil
      begin
        yield
      rescue Exception => error
        primary = error
        raise
      ensure
        begin
          guard!
        rescue Exception => secondary
          begin
            diagnostic(secondary)
          ensure
            raise secondary, cause:secondary.cause unless primary
          end
        ensure
          raise primary, cause:primary.cause if primary
        end
      end
    end

    def negotiate(required)
      value = boundary { @port.negotiate(scope:@scope, required:required) }
      @byte_limit = C.negotiate!(value, @scope, @identity, required)
    end

    def snapshot
      value = boundary { @port.snapshot(scope:@scope, match_ref:@match_ref) }
      C.snapshot!(value, @scope, @match_ref, @expected['account'], @identity)
    end
  end
end
