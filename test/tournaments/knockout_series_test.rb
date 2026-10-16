require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_series'
include GameRoomTest::Assertions
S = GameRoomTournaments::KnockoutSeries
rows = [{'id'=>'leg1', 'participants'=>%w[a b], 'winners'=>['a'], 'scores'=>{'a'=>10,'b'=>2}},
  {'id'=>'leg2', 'participants'=>%w[b a], 'winners'=>['b'], 'scores'=>{'a'=>3,'b'=>8}}]
assert_equal(nil, S.aggregate(units: %w[a b], results: rows.take(1), id: 'pair'))
assert_equal(['a'], S.aggregate(units: %w[a b], results: rows, id: 'pair')['winners'])
assert_equal([], S.aggregate(units: %w[a b], results: rows.map { |r| r.merge('scores'=>nil) }, id: 'pair')['winners'])
equal = rows.map { |r| r.merge('scores'=>{'a'=>5,'b'=>5}) }
assert_equal([], S.aggregate(units: %w[a b], results: equal, id: 'pair')['winners'])
assert_equal(['b'], S.aggregate(units: %w[a b], results: rows.map { |r| r.merge('winners'=>['b']) }, id: 'pair')['winners'])
assert_equal(['b'], S.aggregate(units: %w[a b], results: rows.map { |r| r.merge('score_order'=>'lower') }, id: 'pair')['winners'])
puts 'PASS knockout two-leg series: wait for both, match points, small points, lower-score games, extra-game ties'
