# encoding: UTF-8
require_relative 'coordination_journal'

module GameRoomTournaments
  # Synchroniczna fasada dla przyszłego automatu i „teraz”; wywoływać poza UI.
  # Nigdy Endpoint#create, invite/start/close ani automatyczne ponowienie skutku.
  class CoordinationService
    C = CoordinationContract
    Data = Publication::Data
    attr_reader :diagnostics

    def initialize(port:, trusted_identity:, directory:, registry:, context:)
      @port, @trusted_identity = port, trusted_identity
      # Waliduj surową ścieżkę przed expand_path, jak journal. Baza żyje z usługą.
      Data.text!(directory,bytes:4096)
      raise C::Invalid, :invalid_directory if directory.tr('\\','/').start_with?('//') || directory.match?(/\A[A-Za-z]:(?![\\\/])/)
      @directory=File.expand_path(directory).freeze
      @registry, @context = registry, context
      @mutex, @diagnostics = Mutex.new, []
    end

    def request_match(request:)
      run(request, mutate:true)
    end

    def reconcile(request:)
      run(request, mutate:false)
    end

    private

    def result(state, reason, operation=nil, binding=nil)
      {state:state,reason:reason,operation_id:(operation || @current_operation)&.fetch('operation_id'),binding:binding}.freeze
    end

    def run(raw, mutate:)
      return result(:blocked,:local_busy) unless @mutex.try_lock
      begin
        @current_operation=nil
        unless @port.respond_to?(:identity) && @port.respond_to?(:negotiate)
          return result(:coordination_unavailable,:missing_port)
        end
        return result(:blocked,:incomplete_context) unless @context.respond_to?(:call)
        @request=CoordinationRequest.build(raw.is_a?(CoordinationRequest) ? raw.to_h : raw,registry:@registry).to_h
        guard!
        unless boundary { @port.identity }.eql?(@trusted_identity) && @request['scope']['backend_identity'].eql?(@trusted_identity)
          return result(:coordination_unavailable,:untrusted_port)
        end
        capabilities=boundary { @port.negotiate(scope:@request['scope'],required:C::REQUIRED) }
        @byte_limit=C.capability!(capabilities,@request['scope'],@trusted_identity)
        journal=CoordinationJournal.new(directory:@directory,scope:@request['scope'],account:@expected['account'],registry:@registry,io:method(:boundary))
        journal.with_attempt { |store| progress(store,mutate) }
      rescue C::Blocked => error
        propagate_committed_error!(error)
        result(error.code==:coordination_unavailable ? :coordination_unavailable : :blocked,error.code)
      rescue C::PortUnavailable
        result(:unknown,:port_unavailable)
      rescue Publication::Invalid => error
        propagate_committed_error!(error)
        result(:blocked,error.code)
      rescue CoordinationJournal::Busy
        result(:blocked,:local_busy)
      ensure
        @mutex.unlock
      end
    end

    def propagate_committed_error!(error)
      return unless @current_operation && @port.respond_to?(:effect_confirmed?)
      # To tylko lokalny znacznik TEJ operacji, bez dodatkowego odczytu/cleanup.
      confirmed = true
      begin
        confirmed = @port.effect_confirmed?(@current_operation)
      ensure
        raise error, cause: error.cause if confirmed
      end
    end

    def guard!
      raise C::Blocked, :context_changed if @invalidated
      # identity i czytnik epoki są lokalnymi odczytami zaufanej kompozycji.
      unless @port.identity.eql?(@trusted_identity)
        @invalidated=true
        raise C::Blocked, :port_changed
      end
      current=C.copy(@context.call)
      C.fields!(current,%w[account backend_identity runtime generation epoch cancelled grant_epoch])
      %w[account backend_identity runtime generation].each { |k| Data.text!(current[k],bytes:4096) }
      unless Data.integer?(current['epoch'],1) && Data.integer?(current['grant_epoch'],1) && current['cancelled'].equal?(false) &&
          current['account']==current['account'].downcase && current['backend_identity'].eql?(@trusted_identity) &&
          current['generation'].eql?(@request['execution_generation'])
        @invalidated=true
        raise C::Blocked, :incomplete_context
      end
      @expected ||= Data.freeze_tree(C.copy(current))
      unless current.eql?(@expected)
        @invalidated=true
        raise C::Blocked, :context_changed
      end
    rescue Publication::Invalid
      @invalidated=true
      raise C::Blocked, :incomplete_context
    end

    def boundary(cleanup:false)
      return cleanup_boundary { yield } if cleanup
      guard!
      primary=nil
      begin
        yield
      rescue Exception => error
        primary=[error,error.cause,error.backtrace]
        raise
      ensure
        begin
          guard!
        rescue Exception => secondary
          raise unless primary
          @diagnostics << secondary
        ensure
          # Ensure obejmuje także throw; ambient $! nie jest błędem tej próby.
          if primary
            primary[0].set_backtrace(primary[2])
            raise primary[0], cause:primary[1]
          end
        end
      end
    end

    # Wyłącznie zwolnienie WŁASNEGO uchwytu dyskowego, nigdy native session.
    def cleanup_boundary
      failure=nil
      step=->(&operation) do
        begin
          operation.call
        rescue Exception => error
          failure ||= [error,error.cause,error.backtrace]
          @diagnostics << error
        end
      end
      begin
        step.call { guard! }
      ensure
        begin
          value=step.call { yield }
        ensure
          begin
            step.call { guard! }
          ensure
            if failure
              failure[0].set_backtrace(failure[2])
              raise failure[0], cause:failure[1]
            end
          end
        end
      end
      value
    end

    def snapshot
      C.snapshot!(boundary { @port.snapshot(request:@request) },@request,@expected['account'])
    end

    def progress(store, mutate)
      view=snapshot
      records=store.records(@request)
      records.each { |r| raise C::Blocked,:operation_conflict unless r['operation']['request'].eql?(@request) }
      operations=records.to_h { |r| [r['operation']['kind'],r['operation']] }
      view['shared'].each do |kind,op|
        C.operation!(op,registry:@registry)
        unless op['kind']==kind && op['request'].eql?(@request) && (!operations[kind] || operations[kind].eql?(op))
          raise C::Blocked,:shared_conflict
        end
        roundtrip!(op) unless operations[kind]
      end
      view['shared'].each do |kind,op|
        store.claim(op) unless operations[kind]
        operations[kind]=op
      end
      return readback(store,operations['create_bind']) if operations['create_bind']
      reserve=operations['reserve']; expected=nil
      unless reserve
        return result(:unknown,:no_original_operation) unless mutate
        eligible!(view)
        raise C::Blocked,:grant_already_present unless view['grant'].nil?
        reserve=prepare('reserve',view,nil)
        store.claim(reserve)
        eligible!(snapshot,reference:view)
        expected=call_mutation(reserve)
        return status(expected,reserve) unless expected['status']=='confirmed'
      end
      reserved=lookup(reserve)
      raise C::Blocked,:receipt_conflict if expected && !reserved.eql?(expected)
      return status(reserved,reserve) unless reserved['status']=='confirmed'
      grant=C.grant!(reserved['result'],@request,reserve['preconditions']['ready_versions'])
      store.confirm(reserve,reserved)
      return result(:reserved,:read_only,reserve) unless mutate
      raise C::Blocked,:takeover_required unless reserve['actor'].eql?(@expected['account']) && grant['holder_account'].eql?(@expected['account'])
      fresh=snapshot
      eligible!(fresh,grant:grant)
      create=prepare('create_bind',fresh,grant)
      store.claim(create)
      eligible!(snapshot,reference:fresh,grant:grant)
      response=call_mutation(create)
      return status(response,create) unless response['status']=='confirmed'
      readback(store,create,expected:response)
    end

    def call_mutation(operation)
      @current_operation=operation
      value=boundary do
        operation['kind']=='reserve' ? @port.reserve(operation:operation) : @port.create_bind(operation:operation)
      end
      C.response!(value,operation)
    end

    def lookup(operation)
      @current_operation=operation
      value=boundary { @port.lookup(scope:@request['scope'],kind:operation['kind'],operation_id:operation['operation_id']) }
      C.response!(value,operation)
    end

    def readback(store, operation, expected:nil)
      response=lookup(operation)
      raise C::Blocked,:receipt_conflict if expected && !response.eql?(expected)
      return status(response,operation) unless response['status']=='confirmed'
      binding=C.binding!(response,registry:@registry)
      store.confirm(operation,response)
      result(:bound,:confirmed,operation,binding)
    end

    def status(response,operation)
      result(response['status']=='unsupported' ? :coordination_unavailable : response['status'].to_sym,
        response['reason'].to_sym,operation)
    end

    def eligible!(view, reference:nil, grant:nil)
      # Pełna gotowość jest wymagana przed NOWYM skutkiem, nie historycznym lookup.
      raise C::Blocked,:not_all_ready unless view['ready'].values.all? { |r| r['state']=='ready' }
      C.window!(view,@request)
      if reference && !view.values_at('resource_revision','ready','grant').eql?(reference.values_at('resource_revision','ready','grant'))
        raise C::Blocked,:stale_preconditions
      end
      return unless grant
      ready=view['ready'].transform_values { |r| r['revision'] }
      C.grant!(view['grant'],@request,ready)
      unless view['grant'].eql?(grant) && C.clock!(view['server_time'])<grant['expires_at']
        raise C::Blocked,:stale_grant
      end
    end

    def prepare(kind,view,grant)
      preconditions={'expected_revision'=>view['resource_revision'],
        'ready_versions'=>view['ready'].transform_values { |r| r['revision'] },'window'=>@request['window'],'grant'=>grant}
      operation=C.operation(kind:kind,request:@request,actor:@expected['account'],preconditions:preconditions,operation_id:SecureRandom.uuid)
      roundtrip!(operation)
      operation
    end

    def roundtrip!(operation)
      if @port.respond_to?(:preflight_operation)
        checked = boundary { @port.preflight_operation(operation: operation, max_bytes: @byte_limit) }
        raise C::Blocked, :payload_too_large unless checked.equal?(true)
        return true
      end
      # Projekcja budżetu, nie receipt: maksymalne legalne pola odpowiedzi portu.
      text = '"' * 256
      request = operation['request']
      ready = operation['preconditions']['ready_versions']
      value = if operation['kind'] == 'reserve'
        {'id' => text, 'revision' => text, 'fencing' => Publication::MAX_INTEGER,
          'ready_versions' => ready, 'window' => request['window'], 'holder_account' => operation['actor'],
          'coordinator_epoch' => text, 'expires_at' => Publication::MAX_INTEGER}
      else
        {'native_uuid' => 'ffffffff-ffff-4fff-bfff-ffffffffffff', 'table_id' => Publication::MAX_INTEGER,
          'binding_id' => text, 'binding_revision' => text, 'creator_account' => operation['actor'], 'game_instance' => nil}
      end
      envelope = {'status' => 'confirmed', 'scope' => request['scope'], 'kind' => operation['kind'],
        'operation_id' => operation['operation_id'], 'request_digest' => operation['request_digest'], 'operation' => operation,
        'resource_revision' => text, 'server_time' => {'seconds' => Publication::MAX_INTEGER, 'source' => text},
        'reason' => text, 'receipt' => text, 'result' => value}
      Data.copy(envelope, max_bytes: [@byte_limit, 262_144].min, max_nodes: 16_384, max_depth: 16)
      C.binding!(envelope, registry: @registry) if operation['kind'] == 'create_bind'
      true
    rescue Publication::Invalid => error
      raise C::Blocked, :payload_too_large if error.code == :json_budget
      raise
    end
  end
end
