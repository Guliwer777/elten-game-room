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
    assert_equal(before,f.documents.insert_count,'Selected individual resolved a whole-team match')
    preview=f.preview(loser:'red')
    assert_equal(started ? 'opponent' : 'unstarted',preview['decision']['basis'])
    assert_equal(%w[blue red],preview['summary']['participants'])
    assert_equal([['blue'],['red']],preview['summary']['places'])
    view=f.confirm(preview)
    assert_equal({'blue'=>2,'red'=>0},view['standings'].to_h { |row| [row['unit'],row['points']] })
    assert_equal(view,f.services['Dave'].result_view)
    if started
      assert_equal(%w[Alice Bob Carol Dave],f.h.replay('Alice').players.sort,'Forfeit removed original game participants')
      assert(!f.h.replay('Alice').finished?,'Administrative result fabricated a natural game finish')
    end
  end
end
puts 'PASS native forfeit team units: unstarted and started two-team fixture, no individual winner, original four-player replay preserved, shared 2/0'
