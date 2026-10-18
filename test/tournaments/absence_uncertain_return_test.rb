require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

[:before, :after].each do |failure|
  TournamentForfeitNative.with_fixture do |f|
    f.start
    h, clock = f.h, [0.0]
    runner = P.runner(f, 'Alice', clock)
    step(h, runner)
    h.as('Bob') { h.view('Bob').leave }
    step(h, runner)
    19.times { clock[0] += 15; step(h, runner) }
    assert_equal(285_000, P.presence(h)['totals_ms']['Bob'])
    h.broker.automatic_delivery = false
    native = h.view('Alice')
    native.fail_next_push = failure
    clock[0] += 15
    h.as('Alice') { runner.step }
    assert(runner.take_error.is_a?(EltenAPI::LiveSessions::TimeoutError))
    store = h.transports['Alice'].instance_variable_get(:@live_store)
    pending = store.instance_variable_get(:@rooms).fetch(h.table['__id']).pending_move
    assert(pending && pending.uncertain)
    original = Marshal.load(Marshal.dump(pending.packet))
    original_id = pending.message_id.dup
    assert(h.join('Bob'))
    h.broker.deliver
    clock[0] += 31
    step(h, runner, count: 2)
    snapshot = P.snapshot(h)
    assert(h.transports['Alice'].pending_move_error(h.table['__id']).nil?, 'Presence resolution stranded the pending writer')
    assert_equal(original, pending.packet, 'Recovery rewrote the original packet')
    assert_equal(original_id, pending.message_id, 'Recovery replaced the original UUID')
    if failure == :after
      assert(GameRoomTournamentPresence.ended?(snapshot.session), 'Accepted original result was undone by a return')
      assert(pending.resolution.nil?, 'Confirmed original needlessly wrote a correction')
    else
      assert(!snapshot.session['__frozen'] && !snapshot.session['__aborted'], 'Correction failed to resume a timely return')
      assert(pending.resolution && pending.resolution.message_id != original_id)
      # The actual earlier request arrives only AFTER the accepted correction.
      h.as('Alice') { native.stack_push(original, message_id: original_id) }
      h.broker.deliver(duplicate: true)
      step(h, runner)
      assert(!P.snapshot(h).session['__aborted'], 'A late original overrode the earlier correction')
      assert_equal(:ok, submit(h, runner).first, 'Resolved return could not make a normal move')
    end
    observer = P.observer(f)
    cold = P.runner(f, observer, clock)
    step(h, cold, observer)
    view = P.snapshot(h, observer)
    assert_equal(failure == :after, GameRoomTournamentPresence.ended?(view.session), 'New host reconstructed a different ordered result')
    assert_equal(snapshot.session['__tournament_presence']['totals_ms'], view.session['__tournament_presence']['totals_ms'])
  ensure
    runner&.close
    cold&.close
  end
end

[:before, :after].each do |correction_failure|
  TournamentForfeitNative.with_fixture do |f|
    f.start
    h, clock = f.h, [0.0]
    runner = P.runner(f, 'Alice', clock)
    step(h, runner)
    h.as('Bob') { h.view('Bob').leave }
    h.broker.automatic_delivery = false
    h.view('Alice').fail_next_push = :before
    h.as('Alice') { runner.step }
    assert(runner.take_error.is_a?(EltenAPI::LiveSessions::TimeoutError))
    assert(h.join('Bob'))
    h.broker.deliver
    h.view('Alice').fail_next_push = correction_failure
    clock[0] += 31
    h.as('Alice') { runner.step }
    assert(runner.take_error.is_a?(EltenAPI::LiveSessions::TimeoutError))
    store = h.transports['Alice'].instance_variable_get(:@live_store)
    pending = store.instance_variable_get(:@rooms).fetch(h.table['__id']).pending_move
    assert(pending && pending.resolution && pending.resolution.uncertain)
    correction_id = pending.resolution.message_id
    h.broker.deliver(duplicate: true)
    clock[0] += 31
    step(h, runner)
    assert(h.transports['Alice'].pending_move_error(h.table['__id']).nil?)
    assert(!P.snapshot(h).session['__frozen'])
    assert_equal(correction_id, pending.resolution.message_id, 'Correction retry changed its identity')
    assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == correction_id }, 'Correction was written twice')
    assert_equal(:ok, submit(h, runner).first)
  ensure
    runner&.close
  end
end
puts 'PASS uncertain presence: same UUID, both receipt orders, return, late original and cold successor'
