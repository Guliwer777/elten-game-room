require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_stage'
require_relative '../../lib/tournaments/group_tiebreak'
include GameRoomTest::Assertions
T = GameRoomTournaments
config = {participants: %w[a b c d e f g h i], group_count: nil, places_per_group: nil,
  players_per_match: 2, pairing: 'all_combinations', rematch: false, advancement: T::GroupAdvancement::COMPACT}
plan = T::GroupPlan.build(**config)
groups_results = plan['groups'].map do |group|
  group['matches'].map { |m| m.slice('id','participants').merge('winners'=>[]) }
end
stage = T::GroupStage.calculate(configuration: config, results: groups_results.flatten(1))
groups = stage['groups'].map { |group| group.slice('id','units','places','qualification') }
snapshot = {'policy'=>config[:advancement], 'groups'=>groups, 'results_by_group'=>groups_results, 'wildcard_order'=>{}}
original = Marshal.dump(snapshot)
first = T::GroupTiebreak.build(snapshot: snapshot, attempt: 1)
assert_equal(9, first['matches'].size)
results = first['matches'].map { |m| m.merge('winners'=>[m['participants'].first]) }
partial = T::GroupTiebreak.progress(plan: first, results: results.drop(1))
assert_equal('awaiting_results', partial['state'])
after = T::GroupTiebreak.progress(plan: first, results: results)
assert_equal('seeding_tie_requires_resolution', after['state'])
second = T::GroupTiebreak.build(snapshot: after['snapshot'], attempt: 2)
assert_equal(3, second['matches'].size)
assert(second['qualification']['tasks'].all? { |task| task['group'].nil? }, 'Unexpected group replay after internal ties resolved')
drawn = second['matches'].map { |m| m.merge('winners'=>[]) }
again = T::GroupTiebreak.progress(plan: second, results: drawn)
assert_equal('seeding_tie_requires_resolution', again['state'])
third = T::GroupTiebreak.build(snapshot: again['snapshot'], attempt: 3)
assert_equal(3, third['matches'].size)
decisive = third['matches'].map { |m| m.merge('winners'=>[m['participants'].first]) }
done = T::GroupTiebreak.progress(plan: third, results: decisive)
assert_equal('ready_knockout', done['state'])
assert_equal(4, done['projection']['qualified'].size)
assert(done['projection']['groups'].flat_map { |g| g['qualification']['standings'] }.all? { |r| r['points'] == 2 && r['played'] == 2 }, 'Extra games changed original group points')
assert_equal(original, Marshal.dump(snapshot))
puts 'PASS group tiebreaks: three-way group ties, best runner-up, repeated drawn extra round, four qualifiers and unchanged original scores'
