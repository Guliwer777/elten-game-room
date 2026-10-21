require_relative '../support/tournament_presence_native'
T=GameRoomTournaments
[
  [GameRoomGames::Farkle.new,%w[Alice Bob Carol Dave]],
  [GameRoomGames::Categories.new,%w[Alice Bob Carol]],
  [GameRoomGames::ScientificWar.new,%w[Alice Bob Carol]]
].each do |game,users|
  TournamentForfeitNative.with_fixture(game:game,users:users) do |f|
    f.start
    snapshot=f.h.repositories.fetch('Alice').snapshot_for(f.h.session)
    before=f.documents.insert_count
    error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview(loser:'bob')}
    assert_equal(:match_in_progress,error.code)
    error=assert_raises(T::OrdinaryMatchService::Blocked) do
      f.services['Alice'].forfeit_preview(match_id:f.match['match_id'],leg:1,
        expected_schedule_id:f.candidate['schedule_id'],all_zero:true)
    end
    assert_equal(:match_in_progress,error.code)
    view=f.services['Alice'].result_view(include_match_status:true)
    assert_equal([],view['cancellable_matches'])
    assert_equal([],view['forfeitable_matches'])
    assert_equal(before,f.documents.insert_count)
    assert_equal(snapshot,f.h.repositories.fetch('Alice').snapshot_for(f.h.session))
    assert_equal(users,game.tournament_active_players(f.h.replay('Alice'),options:f.candidate['game_options']))
  end
end
puts 'PASS manual multiplayer continuation/termination removed; every active roster and native history remains intact'
