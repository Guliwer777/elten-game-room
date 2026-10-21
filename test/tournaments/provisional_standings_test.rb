# encoding: UTF-8
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../support/ui'
require_relative '../support/localization'
require_relative '../../lib/tournaments/standings_ranking'
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
t=GameRoomTournaments
criteria=t::StandingsRanking::CRITERIA
results=[{'id'=>'ab','participants'=>%w[a b],'winners'=>['b'],'scores'=>{'a'=>0,'b'=>1}},
  {'id'=>'ac','participants'=>%w[a c],'winners'=>['c'],'scores'=>{'a'=>0,'c'=>1}},
  {'id'=>'zb','participants'=>%w[z b],'winners'=>['b'],'scores'=>{'z'=>0,'b'=>1}}]
before=Marshal.dump(results)
ranked=t::StandingsRanking.calculate(units:%w[a b c y z],results:results,points:t::Standings::MATCH_POINTS,criteria:criteria)
assert_equal(%w[y z a],ranked.select{|row|row['points']==0}.map{|row|row['unit']},'Unplayed/one loss/two losses are ordered alphabetically')
assert_equal([3,3,3],ranked.select{|row|row['points']==0}.map{|row|row['place']},'Games in hand invented a sporting tie-break')
assert_equal(before,Marshal.dump(results),'Provisional sorting changed recorded results')
assert_equal(ranked,t::StandingsRanking.calculate(units:%w[z y c b a],results:results.reverse,points:t::Standings::MATCH_POINTS,criteria:criteria),'Input order changed standings')

%w[en pl cs es ru].each do |language|
  GameRoomTestLocalization.use_language(language)
  view=t::ServerScheduleOverview.allocate
  row={'place'=>1,'unit'=>'team-red','points'=>2,'played'=>2,'scored_matches'=>2,'score_for'=>0,'score_against'=>12,'score_order'=>'lower'}
  original=Marshal.dump(row)
  names={'team-red'=>'Alice + Bob'}
  label=view.send(:standings_row_label,row,names)
  small=GameRoomContent.utf8(GameRoomLocalization.translate('Small points: scored %{scored}, conceded %{conceded}, difference %{difference}'))%{
    scored:0,conceded:12,difference:-12}
  assert(label.include?('Alice + Bob') && !label.include?('team-red'),'Internal team identity leaked')
  assert(label.end_with?(small),'Zero or negative small points are absent from the actual row formatter')
  assert_equal(original,Marshal.dump(row),'Rendering changed score direction or result data')
  partial=row.merge('scored_matches'=>1)
  assert(view.send(:standings_row_label,partial,names).end_with?(small), 'Available partial totals were hidden')
  [row.merge('score_for'=>nil),row.merge('score_against'=>nil),
    row.merge('played'=>0,'scored_matches'=>0)].each do |incomplete|
    label=view.send(:standings_row_label,incomplete,names)
    assert(!label.include?(small),'Missing/partial score was displayed as complete')
  end
end
puts 'PASS provisional standings: fewer played first within unresolved shared places, immutable scores, five-language rows, team names, zero/negative/absent scores'
