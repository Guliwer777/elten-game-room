require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport
with_fixture(game: 'categories', names: %w[Alpha Beta], game_options: {'judge_mode' => 'master'}) do |fixture|
  backend = fixture.backend
  error = assert_raises(T::Publication::Invalid) do
    backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'judge-modern')
  end
  assert_equal(:non_competing_player, error.code)
  # Archived plans keep their old role/result contract; the new eligibility
  # requirement must not retroactively invalidate accepted history.
  legacy = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base,
    intent_id: 'judge-legacy', result_policy: nil)
  record = backend.accept(preview: legacy)
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: 'judge-legacy'))
end
future = Class.new(GameRoomGames::TicTacToe) do
  def id; 'future_with_judge'; end
  def tournament_competitive_roster?(player_count:, options: {}); false; end
end
with_fixture(game: 'future_with_judge', registry: GameRoomGames::Registry.new([future]), names: %w[Alpha Beta]) do |fixture|
  error = assert_raises(T::Publication::Invalid) do
    fixture.backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'future-judge')
  end
  assert_equal(:non_competing_player, error.code)
end
puts 'PASS game-owned competing roster requirement: permanent judge rejected for new plans, legacy archive retained, future games need no ID allowlist'
