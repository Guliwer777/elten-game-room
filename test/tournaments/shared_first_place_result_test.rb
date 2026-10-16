require_relative '../support/tournament_ft2b1_entry'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'
include GameRoomTest::Assertions
T=GameRoomTournaments
players=%w[Ala Bartek Celina]
roster=players.map{|name|{'account'=>name.downcase,'username'=>name}}
%w[farkle quiz categories].each do |id|
  game=GameRoomGames::CATALOG.build(id)
  [[[10,10,0],[3,3,0]],[[10,0,0],[4,1,1]],[[10,10,10],[2,2,2]]].each do |scores,expected|
    score_map=players.zip(scores).to_h
    winners=players.select{|name|score_map[name]==scores.max}
    replay=GameRoomGames::Replay.new(players:players,state:{scores:score_map,winners:winners},
      winner:winners.size==1 ? winners.first : nil,draw:winners.size>1,accepted_events:[])
    replay.define_singleton_method(:finished?){true}
    old=T::GameResult.from_replay(game:game,replay:replay,players:roster,options:{},event_count:0,
      result_policy:T::GameResult::SCORE_ORDER_POLICY)
    assert_equal(winners.size>1,old['draw'],"#{id}: changed historical draw")
    current=T::GameResult.from_replay(game:game,replay:replay,players:roster,options:{},event_count:0,
      result_policy:T::GameResult::CURRENT_RESULT_POLICY)
    assert_equal(scores.uniq.size==1,current['draw'],"#{id}: partial tie became a draw for everyone")
    result=current.slice('participants','winners','scores','score_order').merge('id'=>'match')
    rows=T::Standings.calculate(units:roster.map{|row|row['account']},results:[result],points:T::Standings::MATCH_POINTS)
    assert_equal(expected,rows.map{|row|row['points']},"#{id}: shared places")
  end
end
puts 'PASS Farkle/Quiz/Categories shared first and last places, all-player draw and historical result policy'
