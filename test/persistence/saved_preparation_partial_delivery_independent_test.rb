require_relative '../support/saved_game_preparation_contract'

# Independent of the implementer's final-invitation matrix: switch after the
# first accepted recipient, when another recipient still needs sending. Both
# archive owners outside the playing roster and playing owners are covered.
[false, true].product([:account, :endpoint, :both], [false, true]).each do |privacy, change, observer|
  app, broker, saved = SavedPreparationContract.fixture(private_table: privacy, observer_owner: observer)
  program = app.transport.instance_variable_get(:@program)
  endpoint = program.live_sessions
  task = app.method(:run_network_task)
  changed = false
  app.define_singleton_method(:run_network_task) do |title, **options, &block|
    result = task.call(title, **options, &block)
    if title == 'Sending invitation' && !changed
      changed = true
      $game_room_test_user = 'Other' unless change == :endpoint
      program.live_sessions = broker.endpoint(change == :endpoint ? 'Alice' : 'Other', fresh: true) unless change == :account
    end
    result
  end
  spoken_before = $spoken_messages.length
  assert(app.send(:create_saved_game_table, saved).nil?, 'A late first-recipient delivery opened a stale table')
  assert(changed, 'The test did not reach its first accepted delivery')
  assert(app.notices.grep(Array).map(&:first) == ['Bob'], 'A second recipient crossed the account/endpoint boundary')
  assert($spoken_messages.drop(spoken_before).none? { |line| line.include?('waiting for the original players') },
    'A stale completion announced readiness')

  $game_room_test_user = 'Alice'
  program.live_sessions = endpoint
  app.define_singleton_method(:run_network_task, task)
  row = app.lobby.current_table_for('Alice')
  token = app.transport.membership_token(row['__id'])
  role_state = SavedPreparationContract.core_state(broker, row)
  intent = app.instance_variable_get(:@saved_game_table_preparation)
  assert(intent && intent[:recipients] == (observer ? ['Carol'] : []), 'Confirmed first recipient was not retained inside the worker')
  InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
  restored = app.send(:create_saved_game_table, saved)
  assert(restored && restored['__id'] == row['__id'], 'Explicit retry created another continuation')
  assert(app.transport.membership_token(row['__id']) == token, 'Explicit retry replaced the accepted membership')
  assert(app.lobby.snapshot_for(row).observer?('Alice') == observer, 'Explicit retry changed the archive owner playing role')
  assert(SavedPreparationContract.core_state(broker, row) == role_state, 'Explicit retry rewrote confirmed role state')
  assert(app.activation_calls == [row['__id']], 'Explicit retry repeated activation')
  assert(app.notification_attempts == (observer ? %w[Bob Carol] : %w[Bob]), 'Explicit retry duplicated an accepted recipient')
  assert(app.errors.empty?, 'Identity change produced an unrelated failure')
  SavedPreparationContract.unchanged_archive(app, saved)
  app.lobby.close_table(row)
end

# Case-only spelling is the same account, not a reason to lose a continuation.
app, broker, saved = SavedPreparationContract.fixture
create = app.lobby.method(:create_table)
app.lobby.define_singleton_method(:create_table) do |**options|
  result = create.call(**options)
  $game_room_test_user = 'ALICE'
  result
end
row = app.send(:create_saved_game_table, saved)
assert(row && app.lobby.snapshot_for(row).observer?('Alice'), 'Case-only spelling invalidated the captured owner')
assert(app.notification_attempts == %w[Bob Carol], 'Case-only spelling interrupted recipient delivery')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(row)
$game_room_test_user = 'Alice'

puts 'PASS independent saved preparation: first-recipient account/endpoint boundary, observer/playing owner, exact retry and case identity'
