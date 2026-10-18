require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

TournamentForfeitNative.with_fixture(game: GameRoomGames::Farkle.new, users: %w[Alice Bob Carol Dave]) do |f|
  f.start
  h, clock = f.h, [0.0]
  # Publication organizer and native current host are separate authorities.
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |person| person.user == 'Dave' })
  runner=P.runner(f,'Dave',clock)
  step(h,runner,'Dave')
  before=h.core.entries.size
  preview=f.preview(loser:'bob')
  assert_equal('continue',preview['decision']['mode'])
  assert(!preview.key?('summary'), 'Continuation fabricated final places')
  assert_equal(before,h.core.entries.size,'Read-only preview changed native history')
  begin
    f.confirm(preview,user:'Dave')
    raise 'A host who is not organizer confirmed Ctrl+F'
  rescue GameRoomTournaments::OrdinaryMatchService::Blocked=>error
    assert_equal(:not_organizer,error.code)
  end
  view=f.confirm(preview)
  assert(view['results'].empty?,'Continuation marked fixture complete')
  assert_equal([['Bob']],h.replay('Carol').state[:tournament_eliminations])
  count=h.core.entries.size
  f.confirm(preview)
  assert_equal(count,h.core.entries.size,'Repeated confirmation duplicated elimination')
  assert_equal(%w[Alice Carol Dave],h.game.tournament_active_players(h.replay('Dave'),options:f.candidate['game_options']))
  # A second explicit choice does not forget the first player's last place.
  f.confirm(f.preview(loser:'carol'))
  assert_equal([['Bob'],['Carol']],h.replay('Dave').state[:tournament_eliminations])
  terminal=f.preview(loser:'alice')
  assert_equal('terminal',terminal['decision']['mode'])
  assert_equal([['dave'],['alice'],['carol'],['bob']],terminal['summary']['places'])
  result=f.confirm(terminal)
  assert_equal([['dave'],['alice'],['carol'],['bob']],result['results'].first['summary']['places'])
ensure
  runner&.close
end
puts 'PASS native Ctrl+F continuation: organizer separate from host, read-only preview, retry, original roster and ordered final forfeit'
