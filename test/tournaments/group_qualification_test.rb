require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_qualification'
include GameRoomTest::Assertions
T = GameRoomTournaments
units = %w[a b c]
matches = units.combination(2).map.with_index { |pair, i| {'id' => "m#{i}", 'participants' => pair} }
results = matches.map { |match| match.merge('winners' => [match['participants'].first]) }
input = Marshal.dump([units, matches, results])
project = ->(rows, places = 1) { T::GroupQualification.calculate(units: units, matches: matches, results: rows, places: places) }
assert_equal('awaiting_results', project.call(results.take(2))['state'])
assert_equal([], project.call(results.take(2))['qualified'])
assert_equal(['m2'], project.call(results.take(2))['missing_matches'])
assert_equal(['a'], project.call(results)['qualified'])
assert_equal('ready', project.call(results)['state'])
draws = matches.map { |match| match.merge('winners' => []) }
assert_equal('tie_requires_resolution', project.call(draws)['state'])
assert_equal(units, project.call(draws)['unresolved'])
assert_equal([], project.call(draws)['qualified'])
scored = matches.map.with_index do |match, i|
  match.merge('winners' => [i == 1 ? 'c' : match['participants'].first],
    'scores' => match['participants'].to_h { |unit| [unit, unit == 'b' ? 20 : 1] })
end
assert_equal(['b'], project.call(scored)['qualified'])
assert_equal(['a'], project.call(results.map { |row| row.merge('scores' =>
  row['participants'].to_h { |unit| [unit, unit == 'b' ? 100 : 0] }) })['qualified'])
# A tie below the qualification line does not block advancement.
lower_tie = results.take(2) + [matches.last.merge('winners' => [])]
assert_equal('ready', project.call(lower_tie)['state'])
assert_equal('tie_requires_resolution', project.call(lower_tie, 2)['state'])
assert_equal(['a'], project.call(lower_tie, 2)['qualified'])
assert_equal(1, project.call(lower_tie, 2)['places_remaining'])
assert_raises(T::Publication::Invalid) { project.call(results + [results.first]) }
assert_raises(T::Publication::Invalid) { project.call([results.first.merge('id' => 'foreign')]) }
assert_raises(T::Publication::Invalid) { project.call([results.first.merge('participants' => %w[b a])]) }
assert_equal(units, project.call(results, 3)['qualified'])
assert_equal(units, project.call(draws, 3)['qualified'])
assert_raises(T::Publication::Invalid) { project.call(results, 4) }
assert_raises(T::Publication::Invalid) do
  T::GroupQualification.calculate(units: units, matches: [matches.first], results: [], places: 1)
end
# Arbitrary team IDs and one multiplayer fixture use exactly the same policy.
teams = %w[team_red team_green team_blue]
fixture = {'id' => 'multi', 'participants' => teams}
multi = T::GroupQualification.calculate(units: teams, matches: [fixture],
  results: [fixture.merge('winners' => ['team_green'])], places: 1)
assert_equal(['team_green'], multi['qualified'])
assert_equal(input, Marshal.dump([units, matches, results]))
assert(multi.frozen? && multi['qualified'].frozen?, 'projection is immutable')
puts 'PASS group qualification: complete fixtures, boundary ties, foreign results, teams and multiplayer'
