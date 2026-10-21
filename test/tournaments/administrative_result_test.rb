require_relative '../support/assertions'
require_relative '../../lib/tournaments/administrative_result'
require_relative '../../lib/tournaments/standings_ranking'
require_relative '../../lib/tournaments/knockout_series'
require_relative '../../lib/tournaments/knockout_round'
include GameRoomTest::Assertions
T=GameRoomTournaments
units=%w[a b c d]
build=->(**args) { T::AdministrativeResult.build(units:units,**args) }
calculate=->(summary) { T::Standings.calculate(units:units,results:[summary.reject { |k,_| %w[draw event_count].include?(k) }.merge('id'=>'fixture')],points:T::Standings::MATCH_POINTS) }
normal=build.call(places:[['a'],%w[b c d]],forfeits:[])
forfeit=build.call(places:[['a'],%w[b c d]],forfeits:%w[b c d])
assert_equal([6,2,2,2],calculate.call(normal).map { |row| row['points'] })
assert_equal([6,0,0,0],calculate.call(forfeit).map { |row| row['points'] })
zero=build.call(all_zero:true)
rows=calculate.call(zero)
assert_equal([0,0,0,0],rows.map { |row| row['points'] })
assert(rows.all? { |row| row.values_at('wins','losses','draws') == [0,0,0] },'All-zero is not a draw or a loss')
assert(rows.all? { |row| row['score_for'].nil? },'All-zero must not manufacture game scores')
tie=build.call(places:[units])
assert_equal(true,tie['draw'])
assert_equal([3,3,3,3],calculate.call(tie).map { |row|row['points'] })
assert_raises(T::Publication::Invalid) { build.call(places:[%w[a b],%w[b c d]]) }
assert_raises(T::Publication::Invalid) { build.call(places:[['a'],%w[b c d]],forfeits:['a']) }
assert_raises(T::Publication::Invalid) { build.call(all_zero:true,places:[units]) }
assert_raises(T::Publication::Invalid) { build.call(places:[['a'],%w[b c d]],scores:units.to_h { |u|[u,0] }) }
policy={order:'lower',winner:0,loser:500}
scores=T::AdministrativeResult.suggestions(units:units,forfeits:%w[c d],policy:policy)
assert_equal({'a'=>0,'b'=>0,'c'=>500,'d'=>500},scores)
custom=build.call(places:[['a'],['b'],%w[c d]],forfeits:%w[c d],policy:policy,scores:scores.merge('b'=>80))
assert_equal(80,custom['scores']['b'])
assert_equal('lower',custom['score_order'])
plan=T::KnockoutRound.build(seeds:units,players_per_match:2,round_number:1)
results=plan['matches'].map do |match|
  {'id'=>match['id'],'participants'=>match['participants'],'winners'=>[],'scores'=>nil,'resolution'=>'all_zero'}
end
view=T::KnockoutRound.progress(seeds:units,players_per_match:2,round_number:1,results:results)
assert_equal('completed',view['state'])
assert_equal([],view['next_seeds'])
assert_equal(nil,view['champion'])
results.last.delete('resolution')
results.last['winners']=[results.last['participants'].first]
view=T::KnockoutRound.progress(seeds:units,players_per_match:2,round_number:1,results:results)
assert_equal(results.last['winners'].first,view['champion'])
series=T::KnockoutSeries.wins_projection(units:%w[a b],results:[results.first.merge('participants'=>%w[a b])],id:'series',target:3)
assert_equal('completed',series['state'])
assert_equal('all_zero',series['summary']['resolution'])
scores=[{'id'=>'a-c','participants'=>%w[a c],'winners'=>['a'],'scores'=>{'a'=>11,'c'=>2}},
  {'id'=>'b-c','participants'=>%w[b c],'winners'=>['b'],'scores'=>{'b'=>8,'c'=>3}},
  {'id'=>'a-b','participants'=>%w[a b],'winners'=>[],'scores'=>nil,'resolution'=>'all_zero'}]
ranked=T::StandingsRanking.calculate(units:%w[a b c],results:scores,points:T::Standings::MATCH_POINTS,
  criteria:%w[difference scored head_to_head])
assert_equal([1,2,3],ranked.map { |row|row['place'] },'No-award outcome made complete actual scores unavailable')
missing=scores+[{'id'=>'a-c-return','participants'=>%w[a c],'winners'=>[],'scores'=>nil}]
eligible=ranked.first(2)
assert_equal(nil,T::StandingsRanking.send(:values,eligible,missing,T::Standings::MATCH_POINTS,'difference'),
  'A genuinely missing game score was treated as a zero contribution')
puts 'PASS complete placement groups, forfeit-zero override, editable small scores and no-winner knockout settlement'
