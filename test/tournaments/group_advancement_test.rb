require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_stage'
include GameRoomTest::Assertions
T = GameRoomTournaments
policy = T::GroupAdvancement::AUTOMATIC
(4..256).each do |n|
  count = n <= 16 ? 2 : 4
  sizes = Array.new(count, n / count)
  (n % count).times { |i| sizes[i] += 1 }
  places = T::GroupAdvancement.places(group_sizes: sizes, policy: policy, explicit: nil)
  assert_equal(count, T::GroupAdvancement.group_count(n))
  assert_equal(1 << (n.bit_length - 1), places.sum)
  assert(places.zip(sizes).all? { |p, size| p <= size }, 'qualification fits each group')
end
[4, 6, 8, 10, 12, 16, 18, 20, 32].each do |n|
  configuration = {participants: (1..n).map { |i| "player#{i}" }, group_count: nil,
    places_per_group: nil, advancement: policy, players_per_match: 2,
    pairing: 'all_combinations', rematch: false}
  plan = T::GroupPlan.build(**configuration)
  results = plan['groups'].flat_map { |group| group['matches'].map { |match|
    match.slice('id', 'participants').merge('winners' => [match['participants'].first]) } }
  stage = T::GroupStage.calculate(configuration: configuration, results: results)
  assert_equal('knockout_candidate', stage['state'])
  assert_equal(1 << (n.bit_length - 1), stage['qualified'].size)
  expected = stage['groups'].each_slice(2).flat_map { |left, right|
    left['qualification']['qualified'].zip(right['qualification']['qualified'].reverse) }
  assert_equal(expected, stage['cross_seeding']['pairs'])
  assert_equal(false, stage['dispatch_allowed'])
  assert_equal('awaiting_results', T::GroupStage.calculate(configuration: configuration, results: results.drop(1))['state'])
  draws = results.map { |r| r.merge('winners' => []) }
  tied = T::GroupStage.calculate(configuration: configuration, results: draws)
  assert(['tie_requires_resolution', 'seeding_tie_requires_resolution'].include?(tied['state']), 'ties never silently become pairings')
  assert_equal(nil, tied['knockout'])
end
puts 'PASS automatic largest-power-of-two qualification and cross-group pairings'
