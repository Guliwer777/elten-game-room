require_relative '../support/tournament_forfeit_native'
T = GameRoomTournaments

TournamentForfeitNative.with_fixture do |fixture|
  stale_forfeit = fixture.preview(loser: 'alice')
  fixture.start
  h = fixture.h
  alice, bob = fixture.services.values_at('Alice', 'Bob')
  binding = alice.send(:read_match_binding, fixture.candidate, 5, fixture.match, nil)
  before = h.replay('Alice')
  first = h.game.legal_actions(before, 'Alice').first
  status, plan = h.game.action_for(first, before, 'Alice')
  assert_equal(:ok, status)
  h.submit('Alice', first)

  # A native accepted stale attempt loses its HTTP reply and its callback.
  # Reconciliation recognizes its original UUID rather than sending it again;
  # the game still accepts only the first of the two competing rule actions.
  h.broker.automatic_delivery = false
  h.view('Alice').fail_next_push = :after
  assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', plan.events) }
  pushes = h.view('Alice').calls[:push]
  attempted = h.core.entries.last
  h.as('Alice') { h.transports.fetch('Alice').reconcile(h.table['__id']) }
  assert_equal(pushes, h.view('Alice').calls[:push], 'Accepted game UUID was pushed again')
  assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == attempted['message_id'] })
  h.broker.automatic_delivery = true
  h.broker.deliver
  assert_equal(2, h.events('Alice').size)
  assert_equal(1, h.replay('Alice').accepted_events.size)
  error = assert_raises(T::OrdinaryMatchService::Blocked) { fixture.preview(loser: 'alice') }
  assert_equal(:match_in_progress, error.code, 'An active game allowed a new manual cutoff')

  12.times do
    replay = h.replay('Alice')
    break if replay.finished?
    h.submit(replay.current_player, h.game.legal_actions(replay, replay.current_player).first)
  end
  assert(h.replay('Alice').finished?, 'Fixture did not finish')
  read = lambda do |user|
    h.as(user) do
      T::OrdinaryMatchResults.read(repository: h.repositories.fetch(user), registry: GameRoomGames::CATALOG,
        transport: h.transports.fetch(user), table: h.table, binding: binding)
    end
  end
  captured = read.call('Alice')
  fixture.documents.on_insert = lambda do |row|
    raise IOError, 'Accepted result reply lost' if row['part_index'] == row['part_count']
  end
  assert_raises(IOError) { h.as('Alice') { alice.collect([binding, fixture.candidate, 5, fixture.match, captured]) } }
  fixture.documents.on_insert = nil
  pending = alice.operations.find { |row| JSON.parse(row.fetch('values').fetch('document_json'))['kind'] == 'ordinary-match-result-v1' }
  assert(pending && pending['status'] == 'attempted', 'Result intent was not retained before the lost reply')

  # A later authenticated but rejected move changes the evidence digest, not
  # the sporting result. The second participant may publish that later view.
  h.write('Bob', [GameRoomGames::EventCommand.new(action: 'place', value: '99,99')])
  later = read.call('Bob')
  assert(captured['history_digest'] != later['history_digest'], 'Rejected tail disappeared from evidence')
  assert_equal(captured['summary']['event_count'] + 1, later['summary']['event_count'])
  assert_equal(captured['summary'].reject { |key, _| key == 'event_count' }, later['summary'].reject { |key, _| key == 'event_count' })
  h.as('Alice') { h.transports.fetch('Alice').transfer_room_owner(h.table, 'Bob') }
  h.as('Alice') { h.transports.fetch('Alice').deactivate_table(table_id: h.table['__id']) }
  h.as('Bob') { bob.collect([binding, fixture.candidate, 5, fixture.match, later]) }
  expected = bob.result_view(include_match_status: true)
  assert_equal(1, expected.fetch('results').size)
  assert_equal(captured['history_digest'], expected['results'].first['history_digest'], 'Later participant replaced the first completed receipt')
  assert_equal([0, 2], expected['standings'].map { |row| row['points'] }.sort)

  # Cold recovery uses the retained immutable result, not a live old-host view
  # or a newly fabricated history. Its confirmation adds no second receipt.
  alice.close
  cold = fixture.make_service('Alice')
  begin
    writes = fixture.documents.insert_count
    confirmed = cold.reconcile(pending.fetch('id'))
    assert_equal('confirmed', confirmed.fetch('status'))
    assert_equal(writes, fixture.documents.insert_count, 'Cold recovery duplicated an accepted result')
    assert_equal(expected, cold.result_view(include_match_status: true))
    error = assert_raises(T::OrdinaryMatchService::Blocked) { cold.confirm_forfeit(preview: stale_forfeit) }
    assert_equal(:result_already_recorded, error.code)
    assert_equal(writes, fixture.documents.insert_count, 'Old organizer preview overwrote a completed result')
    assert_equal(1, expected['results'].size)
  ensure
    cold.close
  end
end

puts 'PASS result cross-boundary: stale accepted UUID/lost ACK, immutable rejected evidence, two publisher views, host departure, cold result recovery and stale forfeit refusal'
