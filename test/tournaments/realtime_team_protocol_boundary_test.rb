require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
[
  Class.new(GameRoomGames::AxelPong) do
    def id; 'future_no_point_hook'; end
    def tournament_realtime_point_action; nil; end
  end,
  Class.new(GameRoomGames::AxelPong) do
    def id; 'future_wrong_team_protocol'; end
    def tournament_fixed_team_protocol; 'game-owned-turn-actions-v1'; end
  end
].each do |game_class|
  registry = GameRoomGames::Registry.new([game_class])
  with_fixture(game: game_class.new.id, registry: registry, names: %w[Alice Bob Carol Dave],
    players_per_match: 4, rematch: false, game_options: {'team_size' => 2}) do |fixture|
    with_declared_team_backend(fixture, 'Organizator') do |backend, _authority, directory|
      error = assert_raises(T::Publication::Invalid) do
        backend.preview_pairs(publication_ref: fixture.reference, pairs: [%w[alice bob], %w[carol dave]],
          team_template: [0, 1, 0, 1], intent_id: 'reject-incompatible-team-client')
      end
      assert_equal(:unsupported_role_family, error.code)
      assert(!File.exist?(File.join(directory, 'fixed-teams-v1/sandbox-k02.json')), 'Rejected protocol must not persist a team plan')
      assert(!File.exist?(File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')), 'Rejected protocol must not create a room or readiness')
    end
  end
end
puts 'PASS realtime team boundary: missing agreed-point hook and mismatched execution protocol reject before plan/readiness/room writes'
