require_relative '../support/saved_game_preparation_contract'

# Managed Tasks may complete their native write and deliver the value after a
# runtime switch. The old accepted work stays valid, but must not open its room
# or announce completion in a different account or authenticated endpoint.
[false, true].product([:account, :endpoint, :both], [:current, :created, :role, :invited, :activation, :role_receipt, :created_receipt]).each do |private_table, change, stage|
  app, broker, saved = SavedPreparationContract.fixture(private_table: private_table)
  endpoint = app.transport.instance_variable_get(:@program).live_sessions
  task = app.method(:run_network_task)
  preparation_count = invitation_count = 0
  changed = false
  replace = lambda do
    changed = true
    $game_room_test_user = 'Other' unless change == :endpoint
    target = change == :endpoint ? 'Alice' : 'Other'
    app.transport.instance_variable_get(:@program).live_sessions = broker.endpoint(target, fresh: true) unless change == :account
  end
  if [:activation, :role_receipt, :created_receipt].include?(stage)
    object, method = case stage
    when :activation then [app, :activate_table_transport]
    when :role_receipt then [app.lobby, :set_observer]
    when :created_receipt then [app.lobby, :create_table]
    end
    original = object.method(method)
    object.define_singleton_method(method) do |*args, **keywords, &block|
      result = original.call(*args, **keywords, &block)
      replace.call unless changed
      result
    end
  end
  app.define_singleton_method(:run_network_task) do |title, **options, &block|
    result = task.call(title, **options, &block)
    preparation_count += 1 if title == 'Preparing saved game'
    invitation_count += 1 if title == 'Sending invitation'
    boundary = case stage
    when :current then title == 'Checking the current table'
    when :created then title == 'Preparing saved game' && preparation_count == 1
    when :role then title == 'Preparing saved game' && preparation_count == 2
    when :invited then title == 'Sending invitation' && invitation_count == 2
    end
    if boundary && !changed
      replace.call
    end
    result
  end
  spoken_before = $spoken_messages.length
  result = app.send(:create_saved_game_table, saved)
  label = [private_table, change, stage].inspect
  assert(changed, "Task-delivery fault did not run: #{label}")
  assert(result.nil?, "Old-account preparation returned a room: #{label}")
  assert($spoken_messages.drop(spoken_before).none? { |text| text.include?('waiting for the original players') },
    "Old-account preparation announced completion: #{label}")
  expected_invitations = stage == :invited ? %w[Bob Carol] : []
  assert(app.notices.grep(Array).map(&:first) == expected_invitations,
    "A later invitation ran after the identity changed: #{label}")
  assert(app.errors.empty?, "Identity change became a network/program error: #{label}")

  # Returning to the original endpoint may complete its still-owned setup.
  # Never close accepted membership or repeat already confirmed recipients.
  $game_room_test_user = 'Alice'
  app.transport.instance_variable_get(:@program).live_sessions = endpoint
  app.define_singleton_method(:run_network_task, task)
  retained = app.lobby.current_table_for('Alice')
  native_before = retained && SavedPreparationContract.core_state(broker, retained)
  role = retained && app.lobby.snapshot_for(retained, force: true).observer?('Alice')
  assert(role == [:role, :invited, :role_receipt].include?(stage), "Wrong completed role stage: #{label}") if retained
  assert(!!retained == (stage != :current), "Accepted membership lost or extra room created: #{label}")
  InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
  recovered = app.send(:create_saved_game_table, saved)
  assert(recovered && app.lobby.snapshot_for(recovered).observer?('Alice'), "Original account could not finish setup: #{label}")
  assert(recovered['__id'] == retained['__id'], "Retry created another room: #{label}") if retained
  if [:role, :invited, :role_receipt].include?(stage)
    assert(SavedPreparationContract.core_state(broker, recovered) == native_before, "Retry rewrote accepted role: #{label}")
  end
  assert(app.notices.grep(Array).map(&:first) == %w[Bob Carol], "Retry duplicated confirmed invitations: #{label}")
  assert(app.activation_calls == [recovered['__id']], "Retry repeated activation: #{label}")
  assert(app.instance_variable_get(:@saved_game_table_preparation).nil?, "Finished setup retained an intention: #{label}")
  SavedPreparationContract.unchanged_archive(app, saved)
  app.lobby.close_table(recovered)
end

puts 'PASS saved-game preparation delivery: 42 account/endpoint switches after current/create receipt/create task/activation/role/final invite, preserved accepted work and explicit retry without duplicates'
