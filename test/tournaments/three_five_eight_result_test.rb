require_relative '../support/tournament_ft2b1_entry'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'
require_relative '../../lib/tournaments/local_individual_standings'
include GameRoomTest::Assertions
T=GameRoomTournaments
game=GameRoomGames::CATALOG.build('three_five_eight')
players=%w[Ala Bartek Celina]
roster=players.map{|name|{'account'=>name.downcase,'username'=>name,'seat'=>players.index(name)}}
[[[10,5,0],[4,2,0]],[[10,10,0],[3,3,0]],[[10,0,0],[4,1,1]],[[0,0,0],[2,2,2]]].each do |scores,points|
  score_map=players.zip(scores).to_h
  winners=players.select{|name|score_map[name]==scores.max}
  replay=GameRoomGames::Replay.new(players:players,state:{scores:score_map,winners:winners},
    winner:winners.size==1 ? winners.first : nil,draw:winners.size>1,accepted_events:[])
  replay.define_singleton_method(:finished?){true}
  old=T::GameResult.from_replay(game:game,replay:replay,players:roster,options:{},event_count:0,result_policy:T::GameResult::SCORE_ORDER_POLICY)
  assert_equal(nil,old['scores'],'Historical export was changed')
  assert_equal(winners.size>1,old['draw'])
  current=T::GameResult.from_replay(game:game,replay:replay,players:roster,options:{},event_count:0,result_policy:T::GameResult::CURRENT_RESULT_POLICY)
  assert_equal(scores.uniq.size==1,current['draw'])
  assert_equal(nil,current['scores'],'3-5-8 must not contribute small points under the new policy')
  result=current.slice('participants','winners','scores','score_order','places').merge('id'=>'358')
  rows=T::Standings.calculate(units:roster.map{|row|row['account']},results:[result],points:T::Standings::MATCH_POINTS)
  assert_equal(points,rows.map{|row|row['points']})
  assert(rows.all? { |row| row['score_for'].nil? },'Disabled small points leaked through finishing places')
  legacy=T::GameResult.from_replay(game:game,replay:replay,players:roster,options:{},event_count:0,result_policy:T::GameResult::RANKING_RESULT_POLICY)
  historical=T::Standings.calculate(units:roster.map{|row|row['account']},
    results:[legacy.slice('participants','winners','scores','score_order').merge('id'=>'358')],points:T::Standings::MATCH_POINTS)
  assert_equal(historical.map { |row|row['points'] },rows.map { |row|row['points'] },'Disabling small points changed ordinary placement points')
  record={'preview'=>{'intent_id'=>'rank-only','source'=>{'candidate'=>{'format'=>'round_robin'}}},
    'evidence'=>{'plan'=>{'matches'=>[{'match_id'=>'m','leg'=>1,'players'=>roster}]},'source'=>{'roster'=>roster}}}
  receipt={'record_intent'=>'rank-only','match_id'=>'m','leg'=>1,'summary'=>current}
  progress=T::LocalIndividualStandings.build(record:record,executions:[{'record_intent'=>'rank-only','result'=>receipt}])
  assert_equal(rows.to_h { |row|[row['unit'],row['points']] },
    progress['standings'].to_h { |row|[row['unit'],row['points']] },'Local tournament progress discarded finishing places')
end
puts 'PASS 3-5-8: disabled small points preserve distinct finishing places, first/second/all-place ties and historical large points'
