require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_plan'
include GameRoomTest::Assertions
T = GameRoomTournaments
roster = %w[a b c d e f g]
options = {participants: roster, group_count: 2, places_per_group: 1,
  players_per_match: 2, pairing: 'all_combinations', rematch: false}
plan = T::GroupPlan.build(**options)
assert_equal([%w[a c e g], %w[b d f]], plan['groups'].map { |group| group['units'] })
assert_equal(9, plan['match_count'])
assert_equal(2, plan['qualification_places'])
assert_equal(false, plan['dispatch_allowed'])
ids = plan['groups'].flat_map { |group| group['matches'].map { |match| match['id'] } }
assert_equal(ids.size, ids.uniq.size)
plan['groups'].each do |group|
  results = group['matches'].map { |match| match.slice('id', 'participants').merge('winners' => [match['participants'].first]) }
  outcome = T::GroupQualification.calculate(units: group['units'], matches: group['matches'],
    results: results, places: group['places'])
  assert_equal('ready', outcome['state'])
  assert_equal([group['units'].first], outcome['qualified'])
end
assert_equal(18, T::GroupPlan.build(**options.merge(rematch: true))['match_count'])
# AUTO changes group sizes and advancement, not the round-robin/rematch rule.
[8, 20].product(%w[all_combinations balanced_cycle], [false, true]).each do |size, pairing, rematch|
  automatic = T::GroupPlan.build(**options.merge(participants: (1..size).map { |i| "p#{i}" },
    advancement: T::GroupAdvancement::AUTOMATIC, pairing: pairing, rematch: rematch))
  assert_equal(size <= 16 ? 2 : 4, automatic['groups'].size)
  automatic['groups'].each do |group|
    expected_pairs = group['units'].combination(2).map(&:sort).sort
    assert_equal(rematch ? [1, 2] : [1], group['matches'].map { |match| match['leg'] }.uniq.sort)
    group['matches'].group_by { |match| match['leg'] }.each_value do |leg|
      assert_equal(expected_pairs, leg.map { |match| match['participants'].sort }.sort)
    end
  end
end
assert_equal(plan, T::GroupPlan.build(**options))
assert(plan.frozen? && plan['groups'].first['units'].frozen?, 'immutable plan')
assert_equal(%w[a b c d e f g], roster)
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(group_count: 4)) }
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(places_per_group: 4)) }
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(participants: %w[a A c d])) }
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(participants: ["\xFF".force_encoding('UTF-8'), 'b', 'c', 'd'])) }
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(participants: ['bad\nname', 'b', 'c', 'd'].map { |s| s.gsub('\\n', "\n") })) }
assert_raises(T::LeaguePlan::Invalid) { T::GroupPlan.build(**options.merge(participants: (1..48).map { |i| "p#{i}" })) }
multi = T::GroupPlan.build(**options.merge(participants: (1..12).map { |i| "team#{i}" },
  players_per_match: 3, pairing: 'balanced_cycle'))
assert_equal(12, multi['match_count'])
assert(multi['groups'].all? { |group| group['matches'].all? { |match| match['participants'].size == 3 } }, 'multiplayer groups')
puts 'PASS group plan: bounded cyclic distribution, shared league planner, return legs and qualification'
