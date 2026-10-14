require_relative 'realtime_match_client'
module GameRoomTournaments
  # A UI-issued capability copied from the bound client's agreed point.
  # Workers never call the client or reconstruct a capability from JSON.
  class RealtimePointInput
    FIELDS = %w[request_digest table_id session_id native_uuid control_epoch selection local_data].freeze
    def self.capture(client)
      raise Publication::Invalid, :invalid_composition unless client.instance_of?(RealtimeMatchClient)
      value = client.agreed_input
      value && new(value)
    end
    def initialize(value)
      @value = Publication::Data.freeze_tree(Publication::Data.copy(value))
      freeze
    end
    private_class_method :new
    def to_h; @value; end
    def self.validate!(value, request:, native_uuid:, table_id:, session_id:, control_epoch:, selection:, game:)
      action = game.tournament_realtime_point_action
      unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort &&
          value['request_digest'] == ExecutionPlanContract.digest(request) &&
          value['native_uuid'].eql?(native_uuid) && value['table_id'].eql?(table_id) &&
          value['session_id'].eql?(session_id) && value['control_epoch'].eql?(control_epoch || 'initial') &&
          value['selection'].eql?(selection) && action.is_a?(String) &&
          selection.is_a?(Hash) && selection['kind'] == 'command' && selection['action'] == action &&
          value['local_data'].is_a?(Hash) && value['local_data'].keys == [action] &&
          value['local_data'][action].is_a?(String) && value['local_data'][action].bytesize <= 64 &&
          selection['point'].eql?(value['local_data'][action])
        raise CoordinationContract::Blocked, :native_target_mismatch
      end
      Publication::Data.copy(value['local_data'])
    end
  end
end
