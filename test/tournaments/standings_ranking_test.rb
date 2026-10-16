require_relative '../support/assertions'
require_relative '../../lib/tournaments/standings_ranking'
include GameRoomTest::Assertions
T = GameRoomTournaments
units = %w[a b c]
rows = [
  {'id' => 'ab', 'participants' => %w[a b], 'winners' => ['a'], 'scores' => {'a' => 2, 'b' => 1}},
  {'id' => 'bc', 'participants' => %w[b c], 'winners' => ['b'], 'scores' => {'b' => 20, 'c' => 0}},
  {'id' => 'ca', 'participants' => %w[c a], 'winners' => ['c'], 'scores' => {'c' => 2, 'a' => 0}}]
original = Marshal.load(Marshal.dump(rows))
criteria = %w[head_to_head difference scored]
table = T::StandingsRanking.calculate(units: units, results: rows, points: T::Standings::MATCH_POINTS, criteria: criteria)
assert_equal(%w[b a c], table.map { |row| row['unit'] })
assert_equal([1,2,3], table.map { |row| row['place'] })
assert_equal([2,2,2], table.map { |row| row['points'] })
# Games with no numeric scores preserve a sporting tie, not alphabetic rank.
no_scores = rows.map { |row| row.reject { |key, _| key == 'scores' } }
table = T::StandingsRanking.calculate(units: units, results: no_scores, points: T::Standings::MATCH_POINTS, criteria: criteria)
assert_equal([1,1,1], table.map { |row| row['place'] })
assert_equal([1,1,1], T::StandingsRanking.calculate(units: units, results: [], points: T::Standings::MATCH_POINTS,
  criteria: criteria).map { |row| row['place'] })
assert_equal(original, rows)
penalties = rows.map { |row| Marshal.load(Marshal.dump(row)).merge('score_order' => 'lower') }
lower = T::StandingsRanking.calculate(units: units, results: penalties, points: T::Standings::MATCH_POINTS, criteria: criteria)
assert_equal(%w[c a b], lower.map { |row| row['unit'] })
assert_equal([2, 2, 2], lower.map { |row| row['points'] })
assert_equal(['lower'], lower.map { |row| row['score_order'] }.uniq)
assert_equal(original, rows)
mixed = Marshal.load(Marshal.dump(penalties))
mixed.last['score_order'] = 'higher'
assert_raises(T::Publication::Invalid) { T::StandingsRanking.calculate(units: units, results: mixed,
  points: T::Standings::MATCH_POINTS, criteria: criteria) }
mixed.last.delete('score_order')
assert_raises(T::Publication::Invalid) { T::StandingsRanking.calculate(units: units, results: mixed,
  points: T::Standings::MATCH_POINTS, criteria: criteria) }
direct = [
  {'id' => 'ab', 'participants' => %w[a b], 'winners' => ['a'], 'scores' => {'a' => 1, 'b' => 0}},
  {'id' => 'bc', 'participants' => %w[b c], 'winners' => ['b'], 'scores' => {'b' => 100, 'c' => 0}},
  {'id' => 'ac', 'participants' => %w[a c], 'winners' => ['c'], 'scores' => {'a' => 0, 'c' => 10}},
  {'id' => 'cd', 'participants' => %w[c d], 'winners' => ['c'], 'scores' => {'c' => 1, 'd' => 0}}]
rank = T::StandingsRanking.calculate(units: %w[a b c d], results: direct, points: T::Standings::MATCH_POINTS, criteria: criteria)
assert_equal(%w[c a b d], rank.map { |row| row['unit'] })
penalty_direct = direct.map { |row| row.merge('score_order' => 'lower') }
assert_equal(%w[c a b d], T::StandingsRanking.calculate(units: %w[a b c d], results: penalty_direct,
  points: T::Standings::MATCH_POINTS, criteria: criteria).map { |row| row['unit'] })
assert_equal(%w[c b a d], T::StandingsRanking.calculate(units: %w[a b c d], results: direct,
  points: T::Standings::MATCH_POINTS, criteria: %w[difference scored head_to_head]).map { |row| row['unit'] })
assert_raises(T::Publication::Invalid) { T::StandingsRanking.calculate(units: units, results: rows,
  points: T::Standings::MATCH_POINTS, criteria: ['unknown']) }
puts 'PASS common ranking: three-way mini-table, small points, absent scores, shared places and policy validation'
