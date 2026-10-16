require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_round'
include GameRoomTest::Assertions
T = GameRoomTournaments
seeds = %w[a b c d e]
plan = T::KnockoutRound.build(seeds: seeds, players_per_match: 2, round_number: 1)
assert_equal(['a'], plan['byes'])
assert_equal([%w[b c], %w[d e]], plan['matches'].map { |match| match['participants'] })
assert_equal(false, plan['dispatch_allowed'])
results = plan['matches'].map { |match| match.merge('winners' => [match['participants'].first]) }
advance = ->(rows) { T::KnockoutRound.progress(seeds: seeds, players_per_match: 2, round_number: 1, results: rows) }
assert_equal('awaiting_results', advance.call(results.take(1))['state'])
assert_equal([], advance.call(results.take(1))['next_seeds'])
draw = results.map { |row| row.merge('winners' => []) }
assert_equal('tie_requires_resolution', advance.call(draw)['state'])
assert_equal([], advance.call(draw)['next_seeds'])
assert_equal('tie_requires_resolution', advance.call(results.map { |row| row.merge('winners' => row['participants']) })['state'])
assert_equal(%w[a b d], advance.call(results.reverse)['next_seeds'])
assert_equal('ready_next_round', advance.call(results)['state'])
assert_raises(T::Publication::Invalid) { advance.call(results + [results.first]) }
assert_raises(T::Publication::Invalid) { advance.call([results.first.merge('id' => 'foreign')]) }
assert_raises(T::Publication::Invalid) { advance.call([results.first.merge('participants' => %w[c b])]) }
old_result = results.first
round = 2
current = advance.call(results)['next_seeds']
while current.size > 1
  next_plan = T::KnockoutRound.build(seeds: current, players_per_match: 2, round_number: round)
  assert_raises(T::Publication::Invalid) do
    T::KnockoutRound.progress(seeds: current, players_per_match: 2, round_number: round, results: [old_result])
  end
  own = next_plan['matches'].map { |match| match.merge('winners' => [match['participants'].last]) }
  projection = T::KnockoutRound.progress(seeds: current, players_per_match: 2, round_number: round, results: own)
  current = projection['next_seeds']
  round += 1
end
assert_equal('completed', projection['state'])
assert_equal('d', projection['champion'])
# A fixed three-unit game uses the same elimination contract, including byes.
multi = T::KnockoutRound.build(seeds: %w[red green blue yellow orange], players_per_match: 3, round_number: 1)
assert_equal(%w[red green], multi['byes'])
assert_equal([%w[blue yellow orange]], multi['matches'].map { |match| match['participants'] })
out = T::KnockoutRound.progress(seeds: multi['seeds'], players_per_match: 3, round_number: 1,
  results: multi['matches'].map { |match| match.merge('winners' => ['yellow']) })
assert_equal(%w[red green yellow], out['next_seeds'])
assert_raises(T::Publication::Invalid) { T::KnockoutRound.build(seeds: %w[a b c d], players_per_match: 3, round_number: 1) }
assert_raises(T::Publication::Invalid) { T::KnockoutRound.build(seeds: %w[a A], players_per_match: 2, round_number: 1) }
canonical = ("İ" * 64).downcase
assert_equal(canonical, T::KnockoutRound.build(seeds: [canonical, 'other'], players_per_match: 2, round_number: 1)['seeds'].first)
assert_equal(%w[a b c d e], seeds)
assert(plan.frozen? && plan['matches'].first['participants'].frozen?, 'immutable bracket')
puts 'PASS knockout rounds: explicit seeds, byes, multiplayer, ties, exact results and complete progression'
