require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
require_relative '../../lib/tournaments/individual_native_payload'
require_relative '../../lib/tournaments/individual_native_target_adapter'
include TournamentLocalExecutionPlanSupport
future = Class.new(GameRoomGames::TicTacToe) do
  def id; 'future_game_2026'; end
end
registry = GameRoomGames::Registry.new([future])
with_fixture(game: future.new.id, registry: registry) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'future-game-plan'))
  assert_equal(future.new.id, record['evidence']['source']['game_id'])
  assert_equal(%w[seat:0 seat:1], record['evidence']['plan']['matches'].first['players'].map { |p| p['game_role'] })
  assert_equal(record, fixture.backend.readback(intent_id: 'future-game-plan'))
  match = record['evidence']['plan']['matches'].first
  native = GameRoomTournaments::IndividualNativePayload.from_execution_plan(evidence: record['evidence'],
    expected_source: record['expected_source'], match_id: match['match_id'], leg: match['leg'],
    window_id: match['windows'].first['id'], registry: registry)
  assert_equal(match['players'].map { |p| p['username'] }, native.to_h['players'])
  assert_equal(false, native.to_h['start_allowed'])
  request = GameRoomTournaments::CoordinationRequest.from_execution_plan(evidence: record['evidence'],
    expected_source: record['expected_source'], match_id: match['match_id'], leg: match['leg'],
    window_id: match['windows'].first['id'], registry: registry).to_h
  adapter = GameRoomTournaments::IndividualNativeTargetAdapter.new(
    provider: GameRoomTournaments::IndividualNativeProvider.new(capacity: 2), registry: registry)
  readback, state = adapter.create(state: {'creates' => [], 'cores' => []}, native: native,
    request: request, actor: match['players'].first['account'])
  assert_equal(2, readback['table']['max_players'])
  assert_equal(future.new.id, readback['table']['game'])
  assert_equal(1, state['cores'].size)
end
with_fixture(game: 'farkle', names: %w[Alpha Beta Gamma], players_per_match: 3) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'three-individual-players'))
  assert_equal(2, record['evidence']['plan']['matches'].size)
  assert_equal(%w[seat:0 seat:1 seat:2], record['evidence']['plan']['matches'].first['players'].map { |p| p['game_role'] })
  assert_equal(record['evidence']['plan']['matches'].first['players'].map { |p| p['account'] }.reverse,
    record['evidence']['plan']['matches'].last['players'].map { |p| p['account'] })
  match = record['evidence']['plan']['matches'].last
  native = GameRoomTournaments::IndividualNativePayload.from_execution_plan(evidence: record['evidence'],
    expected_source: record['expected_source'], match_id: match['match_id'], leg: match['leg'],
    window_id: match['windows'].first['id'], registry: GameRoomGames::CATALOG)
  assert_equal(match['players'].map { |p| p['username'] }, native.to_h['players'])
  request = GameRoomTournaments::CoordinationRequest.from_execution_plan(evidence: record['evidence'],
    expected_source: record['expected_source'], match_id: match['match_id'], leg: match['leg'],
    window_id: match['windows'].first['id'], registry: GameRoomGames::CATALOG).to_h
  adapter = GameRoomTournaments::IndividualNativeTargetAdapter.new(
    provider: GameRoomTournaments::IndividualNativeProvider.new(capacity: 3), registry: GameRoomGames::CATALOG)
  readback, state = adapter.create(state: {'creates' => [], 'cores' => []}, native: native,
    request: request, actor: match['players'].first['account'])
  assert_equal(3, readback['table']['max_players'])
  assert_equal(1, readback['participants'].size)
  assert_equal(nil, readback['game_instance'])
  assert_equal(1, state['creates'].size)
  assert_equal('room_created', readback['stack'].first['packet']['kind'])
  assert_raises(GameRoomTournaments::CoordinationContract::Blocked) do
    wrong = GameRoomTournaments::IndividualNativeTargetAdapter.new(
      provider: GameRoomTournaments::IndividualNativeProvider.new(capacity: 2), registry: GameRoomGames::CATALOG)
    wrong.create(state: {'creates' => [], 'cores' => []}, native: native,
      request: request, actor: match['players'].first['account'])
  end
  altered = GameRoomTournaments::Publication::Data.copy(request)
  altered['players'].first['username'] = 'Intruder'
  assert_raises(GameRoomTournaments::CoordinationContract::Blocked) do
    adapter.create(state: {'creates' => [], 'cores' => []}, native: native,
      request: altered, actor: match['players'].first['account'])
  end
end
puts 'PASS future game and three-player individual plan/native creation: real publication, durable acceptance, exact capacity, owner-only admission, no Start, mismatched roster/capacity rejected'
