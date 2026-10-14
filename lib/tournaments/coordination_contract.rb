# encoding: UTF-8
require_relative 'coordination_request'

module GameRoomTournaments
  # Umowa wstrzykiwanego PRZYSZŁEGO portu; żadnych tras HTTP ani adaptera SDK.
  module CoordinationContract
    Data = Publication::Data
    Invalid = Publication::Invalid
    REQUIRED = %w[sealed_plan full_ready atomic_reserve durable_create_bind shared_lookup].to_h { |k| [k.freeze,1] }.freeze
    STATUSES = %w[confirmed pending conflict refused unsupported unknown absent_final].freeze
    class PortUnavailable < StandardError; end
    class Blocked < StandardError
      attr_reader :code
      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end
    module_function

    def copy(value)
      Data.copy(value, max_bytes: 262_144, max_nodes: 16_384, max_depth: 16)
    end

    def fields!(value, names)
      CoordinationRequest.fields!(value, names)
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(copy(value)))
    end

    def capability!(value, scope, identity)
      value = copy(value)
      fields!(value, %w[status identity scope capabilities retention authorization max_bytes])
      unless value['status'] == 'confirmed' && value['identity'].eql?(identity) && value['scope'].eql?(scope) &&
          value['capabilities'].is_a?(Hash) && REQUIRED.all? { |k,v| value['capabilities'][k].eql?(v) } &&
          value['retention'] == 'match_lineage' && value['authorization'] == 'authenticated_participant_or_delegate' &&
          Data.integer?(value['max_bytes'],1)
        raise Blocked, :coordination_unavailable
      end
      value['max_bytes']
    rescue Invalid
      raise Blocked, :coordination_unavailable
    end

    def clock!(value)
      fields!(value, %w[seconds source])
      Data.text!(value['source'], bytes:256)
      raise Invalid, :invalid_clock unless Data.integer?(value['seconds'])
      value['seconds']
    end

    def snapshot!(value, request, account)
      value=copy(value)
      fields!(value, %w[status read_id scope request seal_status resource_revision server_time ready authorized_account delegation competing_operation grant shared])
      unless value['status']=='confirmed' && value['seal_status']=='confirmed' && value['request'].eql?(request) &&
          value['scope'].eql?(request['scope']) && value['authorized_account'].eql?(account)
        raise Blocked, :unconfirmed_plan
      end
      %w[read_id resource_revision].each { |k| Data.text!(value[k],bytes:256) }
      clock!(value['server_time'])
      accounts=request['players'].map { |p| p['account'] }
      unless accounts.include?(account)
        fields!(value['delegation'],%w[account policy_ref])
        Data.text!(value['delegation']['policy_ref'],bytes:256)
        raise Blocked, :not_participant unless value['delegation']['account'].eql?(account)
      end
      fields!(value['ready'],accounts)
      value['ready'].each_value do |r|
        fields!(r,%w[state revision])
        Data.text!(r['revision'],bytes:256)
        # Legalna zmiana gotowości nie odbiera prawa do odczytu starego receipt.
        raise Blocked, :not_all_ready unless %w[ready later withdrawn].include?(r['state'])
      end
      raise Blocked, :competing_operation unless value['competing_operation'].nil?
      raise Invalid, :invalid_shared unless value['shared'].is_a?(Hash) && (value['shared'].keys-%w[reserve create_bind]).empty?
      value
    end

    def window!(snapshot, request)
      now=clock!(snapshot['server_time'])
      w=request['window']
      raise Blocked, :outside_window unless now >= w['opens'] && now < w['closes']
    end

    def grant!(grant, request, ready)
      fields!(grant,%w[id revision fencing ready_versions window holder_account coordinator_epoch expires_at])
      %w[id revision holder_account coordinator_epoch].each { |k| Data.text!(grant[k],bytes:256) }
      unless Data.integer?(grant['fencing'],1) && Data.integer?(grant['expires_at']) &&
          grant['ready_versions'].eql?(ready) && grant['window'].eql?(request['window'])
        raise Blocked, :invalid_grant
      end
      grant
    end

    def operation(kind:, request:, actor:, preconditions:, operation_id:)
      value={'contract_version'=>1,'kind'=>kind,'operation_id'=>operation_id,'request'=>request,
        'actor'=>actor,'preconditions'=>preconditions}
      value['request_digest']=digest(value.reject { |k,_| k=='operation_id' })
      Data.freeze_tree(copy(value))
    end

    def operation!(value, registry:)
      fields!(value,%w[contract_version kind operation_id request_digest request actor preconditions])
      raise Invalid, :invalid_operation unless value['contract_version'].eql?(1) && %w[reserve create_bind].include?(value['kind'])
      %w[operation_id actor].each { |k| Data.text!(value[k],bytes:256) }
      CoordinationRequest.build(value['request'],registry:registry)
      p=value['preconditions']
      fields!(p,%w[expected_revision ready_versions window grant])
      Data.text!(p['expected_revision'],bytes:256)
      fields!(p['ready_versions'],value['request']['players'].map { |person| person['account'] })
      p['ready_versions'].each_value { |v| Data.text!(v,bytes:256) }
      raise Invalid, :invalid_window unless p['window'].eql?(value['request']['window'])
      if value['kind']=='reserve'
        raise Invalid, :invalid_grant unless p['grant'].nil?
      else
        grant!(p['grant'],value['request'],p['ready_versions'])
      end
      expected=digest(value.reject { |k,_| %w[request_digest operation_id].include?(k) })
      raise Invalid, :digest_conflict unless value['request_digest'].eql?(expected)
      value
    end

    def response!(value, operation)
      raise PortUnavailable, 'Brak autorytatywnego odczytu' if value.nil?
      value=copy(value)
      fields!(value,%w[status scope kind operation_id request_digest operation resource_revision server_time reason receipt result])
      unless STATUSES.include?(value['status']) && value['scope'].eql?(operation['request']['scope']) &&
          %w[kind operation_id request_digest].all? { |k| value[k].eql?(operation[k]) } && value['operation'].eql?(operation)
        raise Blocked, :readback_mismatch
      end
      clock!(value['server_time'])
      Data.text!(value['reason'],bytes:256)
      if value['status']=='confirmed'
        %w[resource_revision receipt].each { |k| Data.text!(value[k],bytes:256) }
        raise Invalid, :invalid_result unless value['result'].is_a?(Hash)
      else
        raise Invalid, :invalid_result unless value['result'].nil? && value['receipt'].nil?
        Data.text!(value['resource_revision'],bytes:256) unless value['resource_revision'].nil?
      end
      value
    end

    def binding!(response, registry:)
      op=response['operation']; request=op['request']; result=response['result']
      fields!(result,%w[native_uuid table_id binding_id binding_revision creator_account game_instance])
      %w[binding_id binding_revision].each { |k| Data.text!(result[k],bytes:256) }
      unless result['creator_account'].eql?(op['actor']) && result['game_instance'].nil?
        raise Blocked, :binding_mismatch
      end
      grant=op['preconditions']['grant']
      data=request.reject { |k,_| %w[visibility window].include?(k) }.merge(
        'reservation'=>grant.slice('id','revision','fencing','ready_versions'),
        'create'=>{'operation_id'=>op['operation_id'],'proof_ref'=>response['receipt']},
        'native_uuid'=>result['native_uuid'],'table_id'=>result['table_id'])
      MatchBinding.build(data,registry:registry)
    end
  end
end
