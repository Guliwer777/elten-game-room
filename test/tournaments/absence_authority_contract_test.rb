require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

TournamentForfeitNative.with_fixture do |f|
  f.start
  h = f.h
  base = P.snapshot(h)
  context = h.as('Alice') { f.services['Alice'].presence_context(h.table, base.session, h.replay('Alice'), base.events, decisive: false) }
  valid = GameRoomTournamentPresence.data(session: base.session, fixture: context['fixture'],
    binding_digest: context['binding_digest'], absent: ['Bob'], elapsed_ms: 0)
  variants = [
    ->(d) { d['tournament_presence'] = false },
    ->(d) { d['tournament_presence']['epoch'] = 'unknown' },
    ->(d) { d['tournament_presence']['previous'] = 'unknown' },
    ->(d) { d['tournament_presence']['absent'] = ['Bob', 'Bob'] },
    ->(d) { d['tournament_presence']['absent'] = ['Observer'] },
    ->(d) { d['tournament_presence']['elapsed_ms'] = 1 },
    ->(d) { d['tournament_presence']['elapsed_ms'] = true },
    ->(d) { d['tournament_presence']['fixture']['leg'] = 2 },
    ->(d) { d['tournament_presence']['loser'] = 'Bob'; d['aborted'] = true },
    ->(d) { d['frozen'] = false },
    ->(d) { d['session_id'] += 1 }
  ]
  variants.each_with_index do |mutate, index|
    data = Marshal.load(Marshal.dump(valid))
    mutate.call(data)
    packet = GameRoomEventProtocol.record_packet(kind: 'game_boundary', actor: 'Alice', data: data)
    h.view('Alice').stack_push(packet, message_id: "malformed-presence-#{index}")
    assert(!P.snapshot(h).session.key?('__tournament_presence'), "Malformed boundary #{index} was applied")
  end
  packet = GameRoomEventProtocol.record_packet(kind: 'game_boundary', actor: 'Bob', data: valid)
  h.view('Bob').stack_push(packet, message_id: 'guest-presence')
  assert(!P.snapshot(h).session['__frozen'], 'Guest became absence authority')
  # Correct authenticated data is still rejected at the sender when Bob is present.
  h.as('Alice') { assert(h.transports['Alice'].append_tournament_presence(base.session, data: valid).nil?) }
  h.as('Bob') { h.view('Bob').leave }
  h.as('Alice') { assert(h.transports['Alice'].append_tournament_presence(base.session, data: valid)) }
  assert_equal(['Bob'], P.presence(h)['absent'])
  count = h.core.entries.size
  h.as('Alice') { assert(h.transports['Alice'].append_tournament_presence(base.session, data: valid).nil?) }
  assert_equal(count, h.core.entries.size, 'Stale previous boundary was sent twice')
  assert(h.join('Bob'))
  current = P.snapshot(h)
  data = GameRoomTournamentPresence.data(session: current.session, fixture: context['fixture'],
    binding_digest: context['binding_digest'], absent: [], elapsed_ms: 1000)
  h.as('Alice') { assert(h.transports['Alice'].append_tournament_presence(current.session, data: data)) }
  assert(!P.snapshot(h).session['__frozen'])
  runner = runner_for(h)
  assert_equal(:ok, submit(h, runner).first, 'Valid control chain damaged the ordinary move protocol')
ensure
  runner&.close
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  h, clock = f.h, [0.0]
  runner = P.runner(f, 'Alice', clock)
  step(h, runner)
  h.as('Bob') { h.view('Bob').leave }
  step(h, runner)
  19.times { clock[0] += 15; step(h, runner) }
  snapshot = P.snapshot(h)
  service = f.services['Alice']
  source = service.instance_variable_get(:@source)
  service.instance_variable_set(:@source, -> { value = source.call; value.merge('tournament_id'=>999) })
  count = h.core.entries.size
  error = assert_raises(GameRoomTournaments::OrdinaryMatchService::Blocked) do
    h.as('Alice') { service.presence_context(h.table, snapshot.session, h.replay('Alice'), snapshot.events, decisive: true) }
  end
  assert_equal(:source_changed, error.code)
  assert_equal(count, h.core.entries.size, 'Changed fixture wrote a sporting decision')
ensure
  runner&.close
end
puts 'PASS presence authority: native malformed/foreign/stale boundaries, valid chain and changed fixture'
