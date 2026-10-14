require_relative 'fixed_team_bound_target'
require_relative 'individual_native_payload'
module GameRoomTournaments
  class IndividualBoundTarget < FixedTeamBoundTarget
    def self.native_payload_class; IndividualNativePayload; end
    # The accepted v1 record authenticates request digests; the native payload
    # is a deterministic, validated projection of that exact request.
    def self.native_record_matches?(record, request, native)
      native.to_h['request_digest'] == ExecutionPlanContract.digest(request) &&
        record['request_digests'].dig(request['match_id'], request['window']['id']) == native.to_h['request_digest']
    end
    def self.valid_assignment?(game, options, players)
      game.team_size(options, player_count: players.size).zero?
    end
  end
end
