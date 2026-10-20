require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

[GameRoomGames::AxelPong.new, GameRoomGames::AudioBall.new].each do |game|
  TournamentForfeitNative.with_fixture(game: game) do |fixture|
    fixture.start
    h, clock = fixture.h, [0.0]
    owner = P.runner(fixture, 'Alice', clock)
    guest = P.runner(fixture, 'Bob', clock)
    step(h, owner)
    step(h, guest, 'Bob')
    assert_equal(%w[Alice Bob], game.tournament_active_players(h.replay('Alice'), options: fixture.candidate['game_options']))
    assert(!P.snapshot(h).session['__frozen'], "#{game.id}: present participants froze the match")

    guest.close
    h.as('Bob') { h.view('Bob').leave }
    step(h, owner)
    assert_equal(['Bob'], P.presence(h)['absent'])
    assert(P.snapshot(h).session['__frozen'], "#{game.id}: absent participant did not pause the match")
    clock[0] += 15
    step(h, owner)
    assert_equal(15_000, P.presence(h)['totals_ms']['Bob'])

    assert(h.join('Bob'))
    guest = P.runner(fixture, 'Bob', clock)
    step(h, owner)
    step(h, guest, 'Bob')
    assert(!P.snapshot(h).session['__frozen'], "#{game.id}: return did not resume the match")
    assert_equal(15_000, P.presence(h)['totals_ms']['Bob'])
    assert_equal([], P.presence(h)['absent'])

    h.as('Alice') { h.transports.fetch('Alice').transfer_room_owner(h.table, 'Bob') }
    step(h, owner)
    step(h, guest, 'Bob')
    assert_equal('Bob', guest.presentation_snapshot.table['owner'])
    assert(!P.snapshot(h, 'Bob').session['__frozen'], "#{game.id}: host transfer froze present participants")
    assert_equal(%w[Alice Bob], game.tournament_active_players(h.replay('Bob'), options: fixture.candidate['game_options']))
  ensure
    owner&.close
    guest&.close
  end
end
puts 'PASS Pong and Audio Ball bound tournament start, presence pause/return, cumulative allowance and host transfer through the ordinary runner'
