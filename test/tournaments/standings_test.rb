require_relative '../support/assertions'
require_relative '../../lib/tournaments/standings'
include GameRoomTest::Assertions
T = GameRoomTournaments
players = %w[ala bartek celina]
# A two-player game with a draw and no numeric score.
board = [{'id' => 'board-1', 'participants' => %w[ala bartek], 'winners' => []},
  {'id' => 'board-2', 'participants' => %w[ala celina], 'winners' => ['ala']}]
table = T::Standings.calculate(units: players, results: board)
assert_equal({'unit' => 'ala', 'played' => 2, 'wins' => 1, 'losses' => 0, 'draws' => 1,
  'scored_matches' => 0, 'score_for' => nil, 'score_against' => nil}, table.first)
assert_equal(1, table.find { |r| r['unit'] == 'celina' }['losses'])
# A multiplayer game can have several winning players and optional scores.
cards = [{'id' => 'cards-1', 'participants' => players, 'winners' => %w[ala celina],
  'scores' => {'ala' => 10, 'bartek' => -2, 'celina' => 7}}]
table = T::Standings.calculate(units: players, results: cards)
assert_equal(2, table.sum { |r| r['wins'] })
assert_equal(1, table.sum { |r| r['losses'] })
assert_equal(10, table.first['score_for'])
assert_equal(5, table.first['score_against'])
# The same units represent teams without changing the calculator.
teams = T::Standings.calculate(units: %w[team-A team-B], results: [
  {'id' => 'team-1', 'participants' => %w[team-A team-B], 'winners' => ['team-B']}])
assert_equal(1, teams.last['wins'])
assert_raises(T::Publication::Invalid) { T::Standings.calculate(units: players, results: board + [board.first]) }
assert_raises(T::Publication::Invalid) { T::Standings.calculate(units: players, results: [{'id' => 'bad', 'participants' => players, 'winners' => ['outsider']}]) }
assert_equal(2, board.size)
policy = {'win' => 3, 'draw' => 1, 'loss' => 0}
assert_equal([3, 1, 0], T::Standings.calculate(units: players, results: board,
  points: T::Standings::MATCH_POINTS).map { |row| row['points'] })
awarded = T::Standings.calculate(units: players, results: board, points: policy)
assert_equal([4, 1, 0], awarded.map { |row| row['points'] })
assert_equal(nil, awarded.first['score_for'])
assert_equal([1.5, 0.5, 0.0], T::Standings.calculate(units: players, results: board,
  points: {'win' => 1, 'draw' => 0.5, 'loss' => 0}).map { |row| row['points'] })
assert_equal([3, 0, 3], T::Standings.calculate(units: players, results: cards, points: policy).map { |row| row['points'] })
assert_equal([0, 3], T::Standings.calculate(units: %w[team-A team-B], results: [
  {'id' => 'teams', 'participants' => %w[team-A team-B], 'winners' => ['team-B']}], points: policy).map { |row| row['points'] })
assert_equal([0, 0, 0], T::Standings.calculate(units: players, results: [], points: policy).map { |row| row['points'] })
[{}, policy.merge('extra' => 1), policy.merge('win' => -1), policy.merge('win' => Float::INFINITY),
 policy.merge('draw' => '1'), policy.merge('loss' => nil)].each do |invalid|
  assert_raises(T::Publication::Invalid) { T::Standings.calculate(units: players, results: board, points: invalid) }
end
assert_equal({'win' => 3, 'draw' => 1, 'loss' => 0}, policy)
puts 'PASS shared standings: individual and team units, draws, multiplayer winners, optional game scores, duplicate and foreign winner rejection'
