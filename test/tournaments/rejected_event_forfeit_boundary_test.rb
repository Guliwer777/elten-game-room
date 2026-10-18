require_relative '../support/tournament_forfeit_native'
T = GameRoomTournaments

TournamentForfeitNative.with_fixture do |fixture|
  fixture.start
  h = fixture.h
  first = h.game.legal_actions(h.replay('Alice'),'Alice').first
  _, plan = h.game.action_for(first,h.replay('Alice'),'Alice')
  h.submit('Alice',first)
  h.write('Alice',plan.events)
  assert_equal(2,h.events('Alice').size)
  assert_equal(1,h.replay('Alice').accepted_events.size)
  before = fixture.documents.insert_count
  preview = fixture.preview(loser:'bob')
  assert_equal(before,fixture.documents.insert_count)
  assert_equal(2,preview.fetch('cancelled_game').fetch('event_count'))
  assert_equal(Digest::SHA256.hexdigest(JSON.generate(h.events('Alice'))),preview['cancelled_game']['history_digest'])
  assert_raises(T::OrdinaryMatchService::Blocked) {fixture.confirm(preview,user:'Bob')}
  # Even an ignored but authenticated new packet invalidates old consent;
  # the full snapshot boundary is never reduced to just accepted moves.
  h.write('Bob',[GameRoomGames::EventCommand.new(action:'place',value:'99,99')])
  error = assert_raises(T::OrdinaryMatchService::Blocked) {fixture.confirm(preview)}
  assert_equal(:forfeit_preview_changed,error.code)
  assert_equal(before,fixture.documents.insert_count)
  fresh = fixture.preview(loser:'bob')
  assert_equal(3,fresh['cancelled_game']['event_count'])
  result = fixture.confirm(fresh)
  assert_equal(['alice'],result['results'].first['summary']['winners'])
  assert_equal(result,fixture.services['Bob'].result_view)
end

puts 'PASS native forfeit after rejected action: full immutable boundary, explicit fresh consent, no foreign organizer and both-client result'
