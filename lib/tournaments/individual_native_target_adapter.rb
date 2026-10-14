# encoding: UTF-8
require_relative 'fixed_team_native_target_adapter'
require_relative 'individual_native_payload'
require_relative 'local_fixed_team_native_provider'

module GameRoomTournaments
  class IndividualNativeProvider < LocalFixedTeamNativeProvider
    def initialize(capacity:)
      raise CoordinationContract::Blocked, :native_target_mismatch unless capacity.is_a?(Integer) && capacity.between?(1, 256)
      @capacity = capacity
    end
    def open(state:, owner:)
      Transaction.new(state: state, owner: owner, clock: Clock.new, expected_capacity: @capacity)
    end
  end

  class IndividualNativeTargetAdapter < FixedTeamNativeTargetAdapter
    def preflight!(native:, request:, actor:, state: nil)
      unless native.instance_of?(IndividualNativePayload) && native.to_h['request_digest'] == ExecutionPlanContract.digest(request) &&
          native.to_h['players'] == request['players'].sort_by { |p| p['seat'] }.map { |p| p['username'] } &&
          native.to_h['options'] == request['options']
        raise C::Blocked, :native_target_mismatch
      end
      super
    end

    private
    def match_capacity(request)
      game = @registry.build(request['game_id'])
      count = request['players'].size
      unless request['players'].all? { |p| p['team'].nil? } &&
          game.team_size(request['options'], player_count: count).zero? &&
          game.tournament_capabilities(options: request['options'])[:player_counts].include?(count)
        raise C::Blocked, :native_target_mismatch
      end
      count
    end
  end
end
