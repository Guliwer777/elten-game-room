require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_stage'
require_relative '../../lib/tournaments/group_standings'
include GameRoomTest::Assertions
T = GameRoomTournaments
policy = T::GroupAdvancement::COMPACT
expected = {6 => [3,3], 7 => [4,3], 8 => [4,4], 9 => [3,3,3],
  10 => [4,3,3], 12 => [4,4,4], 13 => [4,3,3,3], 16 => [4,4,4,4],
  18 => [4,4,4,3,3], 20 => [4,4,4,4,4], 24 => [4,4,4,4,4,4]}
expected.each do |n, sizes|
  config = {participants: (1..n).map { |i| "player#{i}" }, group_count: nil,
    places_per_group: nil, advancement: policy, players_per_match: 2,
    pairing: 'all_combinations', rematch: true}
  plan = T::GroupPlan.build(**config)
  assert_equal(sizes, plan['groups'].map { |g| g['units'].size })
  results = plan['groups'].each_with_index.flat_map do |group, index|
    group['matches'].map do |match|
      winner = match['participants'].min_by { |unit| group['units'].index(unit) }
      match.slice('id','participants').merge('winners' => [winner],
        'scores' => match['participants'].to_h { |unit| [unit, unit == winner ? 100 + index : 0] })
    end
  end
  stage = T::GroupStage.calculate(configuration: config, results: results)
  assert_equal('knockout_candidate', stage['state'])
  assert_equal(n == 9 ? 4 : (1 << (n.bit_length - 1)), stage['qualified'].size)
  assert_equal(stage['qualified'].sort, stage['cross_seeding']['pairs'].flatten.sort)
  # The accepted-plan projection uses a separate match ID/leg wire format.
  candidate = {'group_advancement' => policy, 'groups' => plan['groups'].map { |g|
    g.slice('id','units','places').merge('matches' => g['matches'].map { |m| m['id'] }.uniq) },
    'matches' => plan['groups'].flat_map { |g| g['matches'].map { |m|
      {'match_id' => "#{m['id']}-leg#{m['leg']}", 'leg' => m['leg'], 'accounts' => m['participants']} } }}
  candidate['groups'].each_with_index do |g,i|
    g['matches'] = plan['groups'][i]['matches'].map { |m| "#{m['id']}-leg#{m['leg']}" }
  end
  wired = results.each_with_index.map { |r,i| r.merge('id' => JSON.generate([candidate['matches'][i]['match_id'], candidate['matches'][i]['leg']])) }
  projected = T::GroupStandings.calculate(candidate: candidate, units: config[:participants],
    results: wired, unit_key: 'accounts', players_per_match: 2)
  assert_equal('ready_knockout', projected['group_state'])
  assert_equal(stage['qualified'], projected['qualified'])
  assert_equal('awaiting_results', T::GroupStage.calculate(configuration: config, results: results.drop(1))['state'])
  if n == 9
    assert_equal((plan['groups'].map { |g| g['units'].first } + [plan['groups'].last['units'][1]]).sort,
      stage['qualified'].sort)
    tied = results.map { |r| r.reject { |key, _| key == 'scores' } }
    assert_equal('seeding_tie_requires_resolution', T::GroupStage.calculate(configuration: config, results: tied)['state'])
  end
  if n == 10
    comparisons = stage['cross_seeding']['comparison']
    assert_equal([4], comparisons.map { |row| row['played'] }.uniq)
    assert_equal(plan['groups'].first['units'].last, comparisons.first['excluded'])
    assert_equal(6, stage['groups'].first['qualification']['standings'].first['played'])
    # Inflating scores against the excluded last player changes the full
    # group table but never the cross-group comparison or qualifiers.
    bottom = plan['groups'].first['units'].last
    changed = results.map do |r|
      r['participants'].include?(bottom) ? r.merge('scores' => r['scores'].transform_values { |score| score * 1000 }) : r
    end
    other = T::GroupStage.calculate(configuration: config, results: changed)
    assert_equal(stage['cross_seeding'], other['cross_seeding'])
  end
end
(6..256).each do |n|
  count = T::GroupAdvancement.group_count(n, policy: policy)
  sizes = Array.new(count, n / count)
  (n % count).times { |i| sizes[i] += 1 }
  assert(sizes.all? { |size| size.between?(3,4) }, 'bounded group size')
end
puts 'PASS compact groups, wildcard qualification, equal-match comparison, return legs, sporting ties and unchanged full group tables'
