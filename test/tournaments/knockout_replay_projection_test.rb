require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_schedule'
require_relative '../../lib/tournaments/knockout_standings'
include GameRoomTest::Assertions
T = GameRoomTournaments
base = T::KnockoutRound.build(seeds: %w[a b c d], players_per_match: 2, round_number: 1)
resolved = [base['matches'].first.merge('winners' => ['a'])]
plan = T::KnockoutReplay.build(base: base, resolved: resolved, attempt: 1)
assert_equal([%w[c d]], plan['matches'].map { |match| match['participants'] })
assert_equal([], plan['byes'])
metadata = plan.slice('round', 'seeds', 'players_per_match', 'generation', 'replay').merge('phase_digest' => '1' * 64, 'parent_plan_digest' => '2' * 64)
schedule, matches = T::KnockoutSchedule.matches(metadata: metadata, generation: '3' * 64)
candidate = {'knockout' => metadata, 'roster_generation' => '3' * 64, 'schedule_id' => schedule, 'matches' => matches}
calculate = lambda do |winners|
  results = [{'id' => JSON.generate([matches.first['match_id'], 1]), 'participants' => %w[c d], 'winners' => winners}]
  T::KnockoutStandings.calculate(candidate: candidate, units: %w[a b c d], results: results, unit_key: 'players')
end
again = calculate.call([])
assert_equal('tie_requires_resolution', again['knockout_state'])
assert_equal(resolved, again['knockout_resolved_results'])
second = T::KnockoutReplay.build(base: base, resolved: again['knockout_resolved_results'], attempt: 2)
assert_equal([%w[c d]], second['matches'].map { |match| match['participants'] })
assert(second['generation'] != plan['generation'], 'Each replay needs a fresh generation')
decisive = calculate.call(['d'])
assert_equal('ready_next_round', decisive['knockout_state'])
assert_equal(%w[a d], decisive['qualified'])
assert_equal(nil, decisive['champion'])
assert_raises(T::Publication::Invalid) { T::KnockoutReplay.build(base: base, resolved: resolved + resolved, attempt: 1) }
assert_raises(T::Publication::Invalid) { T::KnockoutReplay.build(base: base, resolved: [resolved.first.merge('winners' => [])], attempt: 1) }
assert_raises(T::Publication::Invalid) { T::KnockoutReplay.build(base: base, resolved: [resolved.first.merge('participants' => %w[b a])], attempt: 1) }
# A three-player game retains its actual match size and original byes.
three = T::KnockoutRound.build(seeds: %w[a b c d e], players_per_match: 3, round_number: 2)
replay = T::KnockoutReplay.build(base: three, resolved: [], attempt: 1)
assert_equal(%w[a b], replay['byes'])
assert_equal([%w[c d e]], replay['matches'].map { |match| match['participants'] })
puts 'PASS replay projection: only tied pair repeats, carried winners/byes, ordered next round, repeated draws and invalid source refusal'
