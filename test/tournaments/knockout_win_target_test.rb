require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../../lib/tournaments/knockout_series'
require_relative '../../lib/tournaments/publication'
require_relative '../support/assertions'
include GameRoomTest::Assertions
t=GameRoomTournaments
units=%w[alice bob]
make=->(id,winner,a,b){ {'id'=>id,'participants'=>units,'winners'=>winner ? [winner] : [],'scores'=>{'alice'=>a,'bob'=>b},'score_order'=>'higher'} }
results=[make.call('1','alice',7,3),make.call('2',nil,4,4),make.call('3','bob',2,8)]
project=->(rows){t::KnockoutSeries.wins_projection(units:units,results:rows,id:'series',target:2)}
pending=project.call(results)
assert_equal('awaiting_games',pending['state'])
assert_equal({'alice'=>1,'bob'=>1},pending['wins'])
assert_equal(4,pending['next_game'])
assert_equal(nil,pending['summary'])
results<<make.call('4','alice',5,1)
finished=project.call(results)
assert_equal('completed',finished['state'])
assert_equal(['alice'],finished['summary']['winners'])
assert_equal({'alice'=>18,'bob'=>16},finished['summary']['scores'])
assert_equal(nil,finished['next_game'])
assert_raises(t::Publication::Invalid){project.call(results+[make.call('5','bob',0,9)])}
assert_raises(t::Publication::Invalid){t::KnockoutSeries.wins_projection(units:units,results:[],id:'series',target:0)}
assert_raises(t::Publication::Invalid){project.call([results.first,results.first])}
assert_raises(t::Publication::Invalid){project.call([make.call('1','alice',7,3),make.call('2','bob',2,8).merge('score_order'=>'lower')])}
assert_equal('awaiting_games',project.call([])['state'])
assert(finished.frozen?,'Mutable series projection')
puts 'PASS knockout first-to-wins: draws, split wins, final threshold, complete small scores, duplicate/extra results rejected'
