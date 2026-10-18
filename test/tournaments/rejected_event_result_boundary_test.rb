require_relative '../support/tournament_forfeit_native'
T = GameRoomTournaments

TournamentForfeitNative.with_fixture do |fixture|
  fixture.start
  h = fixture.h
  service = fixture.services.fetch('Alice')
  binding = service.send(:read_match_binding, fixture.candidate, 5, fixture.match, nil)
  before = h.replay('Alice')
  first = h.game.legal_actions(before, 'Alice').first
  status, plan = h.game.action_for(first, before, 'Alice')
  assert_equal(:ok, status)
  h.submit('Alice', first)
  # Both commands were lawful against the same public prefix. The second
  # cannot apply after the first, but its native receipt remains immutable.
  h.write('Alice', plan.events)
  assert_equal(2, h.events('Alice').size)
  assert_equal(1, h.replay('Alice').accepted_events.size)
  12.times do
    replay = h.replay('Alice')
    break if replay.finished?
    h.submit(replay.current_player, h.game.legal_actions(replay, replay.current_player).first)
  end
  assert(h.replay('Alice').finished?, 'Native fixture did not finish')
  read = lambda do |user|
    h.as(user) do
      T::OrdinaryMatchResults.read(repository:h.repositories.fetch(user),registry:GameRoomGames::CATALOG,
        transport:h.transports.fetch(user),table:h.table,binding:binding)
    end
  end
  result = read.call('Alice')
  assert_equal(result, read.call('Bob'))
  assert_equal(h.events('Alice').size, result.fetch('summary').fetch('event_count'))
  assert_equal(Digest::SHA256.hexdigest(JSON.generate(h.events('Alice'))), result.fetch('history_digest'))
  # An invalid move after the winner is known cannot poison the sporting
  # outcome. It still contributes to the full immutable evidence digest.
  sporting = result.fetch('summary').reject { |key, _| key == 'event_count' }
  h.write('Bob', [GameRoomGames::EventCommand.new(action:'place',value:'99,99')])
  poisoned = read.call('Bob')
  assert_equal(sporting, poisoned.fetch('summary').reject { |key, _| key == 'event_count' })
  assert_equal(result['summary']['event_count'] + 1, poisoned['summary']['event_count'])
  assert(result['history_digest'] != poisoned['history_digest'], 'Rejected evidence disappeared from the digest')
  assert_equal(result['summary']['winners'], h.replay('Alice').winner ? [h.replay('Alice').winner.downcase] : [])

  snapshot = h.repositories.fetch('Alice').snapshot_for(h.session)
  capture = lambda do |replay, events|
    T::OrdinaryMatchResults.capture(registry:GameRoomGames::CATALOG,binding:binding,
      session:snapshot.session,replay:replay,events:events)
  end
  replay = h.game.replay(snapshot.session,snapshot.events,h.repositories.fetch('Alice'))
  mutated = replay.dup
  mutated.accepted_events = replay.accepted_events.reverse
  assert_raises(T::Publication::Invalid) { capture.call(mutated,snapshot.events) }
  mutated.accepted_events = replay.accepted_events + [replay.accepted_events.last]
  assert_raises(T::Publication::Invalid) { capture.call(mutated,snapshot.events) }
  mutated.accepted_events = replay.accepted_events.map(&:dup)
  mutated.accepted_events.first['value'] = '3,3'
  assert_raises(T::Publication::Invalid) { capture.call(mutated,snapshot.events) }
  assert_raises(T::Publication::Invalid) { capture.call(replay,snapshot.events.reverse) }
  assert_raises(T::Publication::Invalid) { capture.call(replay,snapshot.events + [snapshot.events.last]) }
  broken = snapshot.events.map(&:dup)
  broken.last.delete('value')
  assert_raises(T::Publication::Invalid) { capture.call(replay,broken) }
  unfinished = h.game.replay(snapshot.session,snapshot.events.first(2),h.repositories.fetch('Alice'))
  assert_raises(T::Publication::Invalid) { capture.call(unfinished,snapshot.events.first(2)) }
  invalid = replay.dup
  invalid.state = {private_cards:true, private_error: :invalid_round}
  assert_raises(T::Publication::Invalid) { capture.call(invalid,snapshot.events) }
  assert_equal(snapshot.events, h.events('Alice'), 'Result export changed the source history')
end

puts 'PASS native rejected-event result: concurrent stale move, post-finish poisoning, both clients, full count/digest, ordered exact accepted subset and invalid-state refusal'
