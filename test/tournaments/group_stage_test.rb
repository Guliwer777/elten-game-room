require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_stage'
include GameRoomTest::Assertions
T = GameRoomTournaments
configuration = {participants: %w[a b c d e f], group_count: 2, places_per_group: 1,
  players_per_match: 2, pairing: 'all_combinations', rematch: false}
plan = T::GroupPlan.build(**configuration)
results = plan['groups'].flat_map do |group|
  group['matches'].map { |match| match.slice('id', 'participants').merge('winners' => [match['participants'].first]) }
end
project = ->(rows, seeds = nil) { T::GroupStage.calculate(configuration: configuration, results: rows, knockout_seeds: seeds) }
assert_equal('awaiting_results', project.call(results.take(3))['state'])
assert_equal(['a'], project.call(results.take(3))['qualified'])
assert_equal('awaiting_seeding', project.call(results)['state'])
assert_equal(nil, project.call(results)['knockout'])
assert_equal(%w[a b], project.call(results)['qualified'])
candidate = project.call(results.reverse, %w[b a])
assert_equal('knockout_candidate', candidate['state'])
assert_equal(%w[b a], candidate['knockout']['matches'].first['participants'])
assert_equal(false, candidate['dispatch_allowed'])
assert_raises(T::Publication::Invalid) { project.call(results.take(3), %w[a b]) }
assert_raises(T::Publication::Invalid) { project.call(results, %w[a a]) }
assert_raises(T::Publication::Invalid) { project.call(results, %w[a c]) }
assert_raises(T::Publication::Invalid) { project.call(results + [results.first]) }
assert_raises(T::Publication::Invalid) { project.call([results.first.merge('id' => 'foreign')]) }
draws = results.map { |row| row.merge('winners' => []) }
assert_equal('tie_requires_resolution', project.call(draws)['state'])
assert_equal([], project.call(draws)['qualified'])
assert_raises(T::Publication::Invalid) { project.call(draws, %w[a b]) }
assert_equal(configuration[:participants], plan['groups'].flat_map { |group| group['units'] }.sort)
assert(candidate.frozen? && candidate['groups'].first['qualification'].frozen?, 'immutable whole stage')
puts 'PASS whole group stage: independent groups, incomplete/tied gates and explicit qualification seeding'
