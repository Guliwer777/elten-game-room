require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
TournamentForfeitNative.with_fixture do |f|
  f.start
  h=f.h
  12.times do
    replay=h.replay('Alice')
    break if replay.finished?
    h.submit(replay.current_player,h.game.legal_actions(replay,replay.current_player).first)
  end
  assert(h.replay('Alice').finished?,'Fixture is still active')
  accepted=h.replay('Alice').accepted_events.size
  h.write('Alice',[GameRoomGames::EventCommand.new(action:'place',value:'99,99')])
  before=f.documents.insert_count
  preview=f.preview(loser:'bob')
  assert_equal(accepted+1,preview.fetch('boundary').fetch('event_count'))
  h.write('Bob',[GameRoomGames::EventCommand.new(action:'place',value:'99,99')])
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(preview)}
  assert_equal(:forfeit_preview_changed,error.code)
  assert_equal(before,f.documents.insert_count)
  fresh=f.preview(loser:'bob')
  assert_equal(accepted+2,fresh['boundary']['event_count'])
  assert_equal(accepted,h.replay('Alice').accepted_events.size)
  result=f.confirm(fresh)
  assert_equal(['alice'],result['results'].first['summary']['winners'])
  assert_equal(result,f.services['Bob'].result_view)
end
puts 'PASS completed-game administrative boundary includes ignored authenticated packets and requires fresh consent'
