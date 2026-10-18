require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative
T = GameRoomTournaments

[:before, :after].each do |failure|
  TournamentForfeitNative.with_fixture(game: GameRoomGames::Farkle.new, users: %w[Alice Bob Carol]) do |f|
    f.start
    h = f.h
    preview = f.preview(loser: 'bob')
    h.broker.automatic_delivery = false
    h.view('Alice').fail_next_push = failure
    assert_raises(EltenAPI::LiveSessions::TimeoutError) { f.confirm(preview) }
    store = h.transports['Alice'].instance_variable_get(:@live_store)
    pending = store.instance_variable_get(:@rooms).fetch(h.table['__id']).pending_move
    assert(pending && pending.uncertain)
    original = Marshal.load(Marshal.dump(pending.packet))
    identity = pending.message_id.dup
    h.broker.deliver(duplicate: true)
    f.confirm(preview)
    assert_equal(identity, pending.message_id)
    assert_equal(original, pending.packet)
    assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == identity })
    assert_equal([['Bob']], h.replay('Carol').state[:tournament_eliminations])
    count = h.core.entries.size
    f.confirm(preview)
    assert_equal(count, h.core.entries.size, 'Repeated accepted confirmation wrote a second decision')
    h.add_client('Bob')
    assert(h.join('Bob'))
    assert_equal([['Bob']], h.replay('Bob').state[:tournament_eliminations], 'Cold replay lost the accepted decision')
  end
end

[:move, :host, :other_decision].each do |change|
  TournamentForfeitNative.with_fixture(game: GameRoomGames::Farkle.new, users: %w[Alice Bob Carol Dave]) do |f|
    f.start
    h, clock = f.h, [0.0]
    preview = f.preview(loser: 'bob')
    case change
    when :move
      context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new)
      h.view('Alice').next_random_values = [1, 2, 3, 4, 5, 6]
      h.submit('Alice', {'kind'=>'dice', 'action'=>'roll'}, context: context)
    when :host
      h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |person| person.user == 'Dave' })
      runner = P.runner(f, 'Dave', clock)
      step(h, runner, 'Dave')
    when :other_decision
      f.confirm(f.preview(loser: 'carol'))
    end
    count = h.core.entries.size
    error = assert_raises(T::OrdinaryMatchService::Blocked) { f.confirm(preview) }
    assert_equal(:forfeit_preview_changed, error.code, 'The UI cannot request fresh consent for this refusal')
    assert_equal(count, h.core.entries.size, 'Stale confirmation mutated the native history')
    assert(!h.game.eliminated_from_game?(h.replay('Alice'), 'Bob'))
    f.confirm(f.preview(loser: 'bob'))
    assert(h.game.eliminated_from_game?(h.replay('Alice'), 'Bob'))
  ensure
    runner&.close
  end
end

[:move, :host].each do |change|
  TournamentForfeitNative.with_fixture(game: GameRoomGames::Farkle.new, users: %w[Alice Bob Carol Dave]) do |f|
    f.start
    h, clock, runner = f.h, [0.0], nil
    context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new)
    h.view('Alice').next_random_values = [2, 3, 4, 6, 2, 3]
    h.submit('Alice', {'kind'=>'dice', 'action'=>'roll'}, context: context)
    assert_equal('Bob', h.replay('Alice').current_player)
    preview = f.preview(loser: 'carol')
    original_preview = Marshal.load(Marshal.dump(preview))
    native = h.view('Alice')
    original_push = native.method(:stack_push)
    sent_id = nil
    native.define_singleton_method(:stack_push) do |packet, message_id:|
      if !sent_id && packet['kind'] == 'game_boundary' && packet.dig('data', 'tournament_presence', 'origin') == 'organizer'
        sent_id = message_id
        if change == :move
          h.view('Bob').next_random_values = [1, 2, 3, 4, 6, 2]
          h.submit('Bob', {'kind'=>'dice', 'action'=>'roll'}, context: context)
        else
          transfer_ownership(participants.find { |person| person.user == 'Dave' })
          runner = P.runner(f, 'Dave', clock)
          step(h, runner, 'Dave')
        end
      end
      original_push.call(packet, message_id: message_id)
    end
    changes = f.changes.size
    error = assert_raises(T::OrdinaryMatchService::Blocked) { f.confirm(preview) }
    assert_equal(:forfeit_preview_changed, error.code, 'A stored but rejected decision reported success')
    assert_equal(changes, f.changes.size, 'Rejected confirmation published a result-change notification')
    assert(sent_id, 'The test did not reach the real native mutation boundary')
    assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == sent_id })
    assert_equal(original_preview, preview, 'The stale confirmation was rewritten')
    assert(!h.game.eliminated_from_game?(h.replay('Bob'), 'Carol'))
    h.as('Alice') { h.transports.fetch('Alice').reconcile(h.table['__id']) }
    fresh = f.preview(loser: 'carol')
    f.confirm(fresh)
    assert_equal([['Carol']], h.replay('Bob').state[:tournament_eliminations])
    f.confirm(f.preview(loser: 'dave'))
    count = h.core.entries.size
    f.confirm(fresh)
    assert_equal(count, h.core.entries.size, 'Later accepted decisions invalidated an already accepted UUID')
    assert_equal([['Carol'], ['Dave']], h.replay('Bob').state[:tournament_eliminations])
  ensure
    runner&.close
  end
end

TournamentForfeitNative.with_fixture(game: GameRoomGames::Farkle.new, users: %w[Alice Bob Carol]) do |f|
  f.start
  h = f.h
  preview = f.preview(loser: 'bob')
  transport = h.transports.fetch('Alice')
  original_append = transport.method(:append_tournament_presence)
  received = nil
  transport.define_singleton_method(:append_tournament_presence) do |session, **options|
    record = original_append.call(session, **options)
    unless received
      received = record
      h.view('Alice').fail_next_read = EltenAPI::LiveSessions::TimeoutError.new('post-ACK read unavailable')
    end
    record
  end
  changes = f.changes.size
  assert_raises(EltenAPI::LiveSessions::TimeoutError) { f.confirm(preview) }
  assert(received, 'No real native receipt preceded the read failure')
  assert_equal(changes, f.changes.size, 'An unavailable acceptance read reported success')
  count = h.core.entries.size
  f.confirm(preview)
  assert_equal(count, h.core.entries.size, 'Recovery replaced the accepted decision')
  assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == received.message_id })
  assert_equal([['Bob']], h.replay('Carol').state[:tournament_eliminations])
end
puts 'PASS continuation recovery: before/after ACK, immutable UUID, cold replay and stale preflight/dispatch move/epoch/decision refusal'
