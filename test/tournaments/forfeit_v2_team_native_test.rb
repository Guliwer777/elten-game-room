require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
[false,true].each do |started|
  game=GameRoomGames::Domino.new
  options=game.normalize_options(game.default_options.merge('teams'=>true,'team_count'=>'2'))
  TournamentForfeitNative.with_fixture(game:game,users:%w[Alice Bob Carol Dave],options:options) do |f|
    f.candidate.merge!('players_per_match'=>4,'team_template'=>[0,1,0,1],
      'membership'=>{'version'=>1,'kind'=>'fixed-teams','units'=>[
        {'unit_id'=>'red','accounts'=>%w[alice bob]}, {'unit_id'=>'blue','accounts'=>%w[carol dave]}]})
    f.match['unit_ids']=%w[red blue]
    f.start if started
    before=f.documents.insert_count
    assert_raises(T::OrdinaryMatchService::Blocked) {f.preview(loser:'bob')}
    if started
      error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview(loser:'red')}
      assert_equal(:match_in_progress,error.code)
      preview=f.legacy_preview(loser:'red')
      view=f.insert_historical(preview)
      assert(view['standings'].all? { |row|row['score_for'].nil? },'Historical v2 changed score policy')
      assert_equal(%w[Alice Bob Carol Dave],f.h.replay('Alice').players.sort)
      assert(!f.h.replay('Alice').finished?,'Historical receipt fabricated natural completion')
    else
      preview=f.preview(loser:'red')
      assert_equal('unbound',preview['boundary']['status'])
      assert_equal({'blue'=>0,'red'=>100},preview['summary']['scores'])
      view=f.confirm(preview)
    end
    assert_equal([['blue'],['red']],preview['summary']['places'])
    assert_equal({'blue'=>2,'red'=>0},view['standings'].to_h { |row|[row['unit'],row['points']] })
    assert_equal(view,f.services['Dave'].result_view)
    assert(f.documents.insert_count>before,'Receipt fixture was not read through actual table storage')
  end
end
puts 'PASS indivisible team units: current technical 0:100, no active interruption, historical v2 interpretation and cold team reader'
