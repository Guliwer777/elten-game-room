# encoding: UTF-8
require_relative 'publication'
require 'digest'

module GameRoomTournaments
  # Schemat PROPONOWANEGO portu K03; nie implementacja API serwera.
  module ReadinessContract
    Data = Publication::Data
    Invalid = Publication::Invalid
    READ = %w[per_account_acl own_readback].to_h { |key| [key.freeze, 1] }.freeze
    WRITE = READ.merge(%w[accepted_match ready_cas start_gate_invalidation durable_operation no_hidden_retry].to_h { |key| [key.freeze, 1] }).freeze
    STATUSES = %w[confirmed pending unknown conflict refused unsupported].freeze
    class PortUnavailable < StandardError; end
    class KnownRefused < StandardError; end
    class Blocked < StandardError
      attr_reader :code
      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end
    module_function

    def copy(value, max_bytes:65_536)
      Data.copy(value, max_bytes:[65_536,max_bytes].min, max_nodes:8192, max_depth:16)
    end

    def frozen_copy(value)
      Data.freeze_tree(copy(value))
    end

    def fields!(value, names)
      raise Invalid, :invalid_fields unless value.is_a?(Hash) && value.keys.sort.eql?(names.sort)
    end

    def text!(value)
      Data.text!(value, bytes: 4096)
    end

    def target!(scope, match_ref)
      fields!(scope, %w[app_uuid backend_identity tournament_id])
      scope.each_value { |value| text!(value) }
      fields!(match_ref, %w[plan_id match_id leg roster_generation])
      %w[plan_id match_id roster_generation].each { |key| text!(match_ref[key]) }
      raise Invalid, :invalid_leg unless Data.integer?(match_ref['leg'], 1)
    end

    def negotiate!(value, scope, identity, required)
      value = copy(value)
      fields!(value, %w[status identity scope capabilities authorization retention max_bytes])
      unless value['status']=='confirmed' && value['identity'].eql?(identity) && value['scope'].eql?(scope) &&
          value['capabilities'].is_a?(Hash) && required.all? { |k,v| value['capabilities'][k].eql?(v) } &&
          value['authorization']=='own_account' && value['retention']=='match_lineage' && Data.integer?(value['max_bytes'],1)
        raise Blocked, :unsupported
      end
      value['max_bytes']
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(copy(value)))
    end

    def accepted_match!(value, account)
      fields!(value, %w[status plan_digest full_roster members roles_status])
      unless value['status']=='confirmed' && value['full_roster'].equal?(true) && value['roles_status']=='confirmed'
        raise Blocked, :unconfirmed_plan
      end
      raise Invalid, :invalid_plan_digest unless value['plan_digest'].is_a?(String) && value['plan_digest'].match?(/\A[0-9a-f]{64}\z/)
      members=value['members']
      raise Invalid, :invalid_members unless members.is_a?(Array) && members.size.between?(1,256)
      members.each do |person|
        fields!(person, %w[account kind role])
        text!(person['account'])
        unless person['account'].eql?(person['account'].downcase) && %w[human bot].include?(person['kind']) && %w[player observer].include?(person['role'])
          raise Invalid, :invalid_member
        end
      end
      raise Invalid, :duplicate_member unless members.map { |p| p['account'] }.uniq.size==members.size
      own=members.find { |p| p['account'].eql?(account) }
      raise Blocked, :not_participant unless own && own['kind']=='human' && own['role']=='player'
    end

    def eligible!(view, request, account)
      raise Blocked, :unconfirmed_plan unless view['status']=='confirmed'
      accepted_match!(view['accepted_match'], account)
      policy=view['policy']
      fields!(policy, %w[status ref allows])
      unless policy['status']=='confirmed' && policy['ref'].eql?(request['policy_ref']) &&
          policy['allows'].is_a?(Array) && policy['allows'].include?(request['availability'])
        raise Blocked, :unconfirmed_policy
      end
      raise Blocked, :already_started unless view['phase']=='not_started'
      raise Blocked, :stale_revision unless view['current']['ready_revision'].eql?(request['expected_ready_revision'])
    end

    def operation(request, account, accepted_match, operation_id)
      value={'version'=>1,'operation_id'=>operation_id,'request'=>request,'account'=>account,'accepted_match'=>accepted_match}
      value['request_digest']=digest(value.reject { |k,_| k=='operation_id' })
      operation!(value)
    end

    def operation!(value)
      value=copy(value)
      fields!(value, %w[version operation_id request account accepted_match request_digest])
      raise Invalid, :invalid_version unless value['version'].eql?(1)
      unless value['operation_id'].is_a?(String) && value['operation_id'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
        raise Invalid, :invalid_operation_id
      end
      ReadinessRequest.build(value['request'])
      accepted_match!(value['accepted_match'],value['account'])
      expected=digest(value.reject { |k,_| %w[operation_id request_digest].include?(k) })
      raise Invalid, :invalid_digest unless value['request_digest'].eql?(expected)
      frozen_copy(value)
    end

    # Budżet obejmuje również obowiązkowe opakowanie dokładnego readback.
    # Rewizja i czas mogą zająć cały dozwolony zakres Integer; nie szacujemy znaków.
    def roundtrip!(operation, max_bytes:)
      envelope={'status'=>'confirmed','operation'=>operation,'request_digest'=>operation['request_digest'],
        'reason'=>'confirmed','result'=>{'account'=>operation['account'],
          'ready_revision'=>Publication::MAX_INTEGER,'state'=>operation['request']['availability'],
          'server_time'=>Publication::MAX_INTEGER,'invalidated_grants'=>[]}}
      copy(envelope,max_bytes:max_bytes)
      true
    rescue Invalid => error
      raise Blocked, :payload_too_large if error.code==:json_budget
      raise
    end

    def response!(value, operation, max_bytes:65_536)
      raise PortUnavailable, 'Brak odczytu operacji K03' if value.nil?
      value=copy(value,max_bytes:max_bytes)
      fields!(value, %w[status operation request_digest reason result])
      unless STATUSES.include?(value['status']) && value['operation'].eql?(operation) && value['request_digest'].eql?(operation['request_digest'])
        raise Blocked, :readback_mismatch
      end
      text!(value['reason'])
      if value['status']=='confirmed'
        data=value['result']; request=operation['request']
        fields!(data, %w[account ready_revision state server_time invalidated_grants])
        unless data['account'].eql?(operation['account']) && data['state'].eql?(request['availability']) &&
            Data.integer?(data['ready_revision']) && data['ready_revision']>request['expected_ready_revision'] &&
            Data.integer?(data['server_time']) && data['invalidated_grants'].is_a?(Array) && data['invalidated_grants'].size<=256
          raise Blocked, :receipt_mismatch
        end
        data['invalidated_grants'].each { |id| text!(id) }
        raise Invalid, :duplicate_grant unless data['invalidated_grants'].uniq.eql?(data['invalidated_grants'])
      else
        raise Invalid, :invalid_result unless value['result'].nil?
      end
      frozen_copy(value)
    end

    def snapshot!(value, scope, match_ref, account, identity)
      value = copy(value)
      fields!(value, %w[status identity scope match_ref account accepted_match policy current phase])
      unless STATUSES.include?(value['status']) && value['identity'].eql?(identity) && value['scope'].eql?(scope) &&
          value['match_ref'].eql?(match_ref) && value['account'].eql?(account)
        raise Blocked, :snapshot_mismatch
      end
      return frozen_copy(value) unless value['status']=='confirmed'
      fields!(value['current'], %w[state ready_revision server_time])
      unless %w[unknown ready later withdrawn].include?(value['current']['state']) &&
          Data.integer?(value['current']['ready_revision']) && Data.integer?(value['current']['server_time']) &&
          %w[not_started started].include?(value['phase'])
        raise Invalid, :invalid_current
      end
      frozen_copy(value)
    end
  end
end
