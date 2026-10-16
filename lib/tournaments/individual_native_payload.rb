# encoding: UTF-8
require_relative 'fixed_team_native_payload'

module GameRoomTournaments
  # Verified individual roster/options for native creation. No start authority.
  class IndividualNativePayload < FixedTeamNativePayload
    def self.from_execution_plan(evidence:, expected_source:, match_id:, leg:, window_id:, registry:)
      data = ExecutionPlanContract.copy(evidence)
      raise Publication::Invalid, :wersja_planu unless data.is_a?(Hash) && data['version'].eql?(1)
      request = CoordinationRequest.from_execution_plan(evidence: data, expected_source: expected_source,
        match_id: match_id, leg: leg, window_id: window_id, registry: registry)
      value = request.to_h
      people = value['players'].sort_by { |person| person['seat'] }
      game = registry.build(value['game_id'])
      unless people.all? { |person| person['team'].nil? } &&
          game.team_size(value['options'], player_count: people.size).zero? &&
          game.tournament_roles(player_count: people.size, options: value['options']) == people.map { |p| p['game_role'] } &&
          game.tournament_role_policy(player_count: people.size, options: value['options']) == value['role_policy_ref']
        raise Publication::Invalid, :unassigned_roles
      end
      new(Publication::Data.freeze_tree(ExecutionPlanContract.copy({'request_digest' => request.digest,
        'players' => people.map { |person| person['username'] }, 'options' => value['options'],
        'dispatch_allowed' => false, 'start_allowed' => false})))
    end
  end
end
