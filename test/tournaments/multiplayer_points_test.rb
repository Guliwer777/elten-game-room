require_relative '../support/assertions'
require_relative '../../lib/tournaments/standings_ranking'
include GameRoomTest::Assertions
T=GameRoomTournaments

def standings(scores,winners:nil,order:'higher')
  players=scores.keys
  best=order=='higher' ? scores.values.max : scores.values.min
  winners ||= scores.select{|_,score|score==best}.keys
  winners=[] if winners.size==players.size
  T::StandingsRanking.calculate(units:players,results:[{'id'=>'match','participants'=>players,
    'winners'=>winners,'scores'=>scores,'score_order'=>order}],points:T::Standings::MATCH_POINTS,
    criteria:T::StandingsRanking::CRITERIA)
end

# Every ordered tie pattern, not only distinct scores or tied first places.
patterns=0
(2..8).each do |count|
  players=Array.new(count){|index|"player#{index}"}
  (0...(1<<(count-1))).each do |mask|
    rank=0
    scores=players.each_with_index.to_h do |name,index|
      rank+=1 if index>0 && mask[index-1]==1
      [name,-rank]
    end
    expected=players.map do |name|
      score=scores.fetch(name)
      worse=scores.values.count{|other|other<score}
      tied=scores.values.count(score)-1
      [name,2*worse+tied,1+scores.values.count{|other|other>score}]
    end
    [scores,scores.to_a.reverse.to_h].each do |values|
      rows=standings(values)
      assert_equal(expected,rows.map{|row|row.values_at('unit','points','place')})
      assert_equal(count*(count-1),rows.sum{|row|row['points']})
      assert(rows.all?{|row|row['points'].is_a?(Integer)})
    end
    lower=standings(scores.transform_values{|score|-score},order:'lower')
    assert_equal(expected,lower.map{|row|row.values_at('unit','points','place')})
    patterns+=1
  end
end

# The declared winner takes precedence over small points (e.g. sets/rallies).
rows=standings({'a'=>5,'b'=>100},winners:['a'])
assert_equal([['a',2],['b',0]],rows.map{|row|row.values_at('unit','points')})
co_winners=standings({'a'=>10,'b'=>9,'c'=>1},winners:%w[a b])
assert_equal([3,3,0],co_winners.map{|row|row['points']})
unknown=T::Standings.calculate(units:%w[a b c d],results:[{'id'=>'unknown','participants'=>%w[a b c d],'winners'=>['a']}],points:T::Standings::MATCH_POINTS)
assert_equal([6,2,2,2],unknown.map{|row|row['points']})
teams=T::Standings.calculate(units:%w[team1 team2],results:[{'id'=>'team','participants'=>%w[team1 team2],'winners'=>['team2']}],points:T::Standings::MATCH_POINTS)
assert_equal([0,2],teams.map{|row|row['points']})
puts "PASS pairwise tournament points: #{patterns} ordered tie patterns for 2–8 players, permutations, lower scores, integer totals, teams and winner precedence"
