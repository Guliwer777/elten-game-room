require_relative '../support/invitation_fresh_endpoint'

def invitation_account_fixture(private_table: false)
  InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
  broker, gateway = NativeLiveSessionsBroker.new, DurableNoticeGateway.new
  alice, bob = %w[Alice Bob].map { |user| InvitationAppDriver.new(broker, user, gateway) }
  $game_room_test_user = 'Alice'
  table = alice.transport.create_room(name: 'Account completion boundary', game: 'uno',
    owner: 'Alice', game_options: '{}', private_table: private_table)
  alice.send(:deliver_table_invitation, table, 'Bob')
  $game_room_test_user = 'Bob'
  invitation = bob.send(:load_pending_invitations).first.fetch(:invitation)
  [broker, gateway, bob, table, invitation]
end

def replace_invitation_account(broker, app, kind)
  $game_room_test_user = 'Other' unless kind == :endpoint
  unless kind == :session
    app.transport.instance_variable_get(:@program).live_sessions = broker.endpoint('Other')
  end
end

def after_invitation_call(object, method, &after)
  original = object.method(method)
  object.define_singleton_method(method) do |*args, **options, &block|
    result = original.call(*args, **options, &block)
    after.call
    result
  end
end

[false, true].product([:session, :endpoint, :both], [:establish, :reconnect, :role, :response, :task_delivery]).each do |private_table, kind, stage|
  broker, gateway, app, table, invitation = invitation_account_fixture(private_table: private_table)
  change = -> { replace_invitation_account(broker, app, kind) }
  case stage
  when :establish, :reconnect
    app.send(:establish_invited_table_transport, invitation.table) if stage == :reconnect
    after_invitation_call(app, :establish_invited_table_transport, &change)
  when :role
    after_invitation_call(app, :apply_game_join_role, &change)
  when :response
    after_invitation_call(app.instance_variable_get(:@invitations), :respond, &change)
  when :task_delivery
    original = app.method(:run_network_task)
    app.define_singleton_method(:run_network_task) do |title, **options, &block|
      result = original.call(title, **options, &block)
      change.call if title == 'Accepting invitation'
      result
    end
  end
  result = app.send(:accept_pending_invitation, invitation)
  core = broker.cores.fetch(table['__live_session_id'])
  label = [private_table, kind, stage].inspect
  assert(result.nil?, "Stale acceptance returned a table: #{label}")
  assert(core.participants.keys.sort == %w[alice bob], "New account joined or old accepted membership was removed: #{label}")
  assert(gateway.rows['Bob'].none?(&:revoked), "Old notification revoked after account boundary: #{label}") unless stage == :task_delivery
  assert(app.errors.empty?, "Account boundary escaped as an exception: #{label}: #{app.errors.inspect}")
end

# Manual table selection uses the same invitation completion chain. The native
# request may have succeeded, but the old worker must not enter the new account.
[:session, :endpoint, :both].product([:establish, :task_delivery]).each do |kind, stage|
  broker, gateway, app, table, invitation = invitation_account_fixture
  snapshot = LobbyRepository::TableSnapshot.new(table: invitation.table, members: ['Alice'], bots: [])
  if stage == :task_delivery
    original = app.method(:run_network_task)
    app.define_singleton_method(:run_network_task) do |title, **options, &block|
      result = original.call(title, **options, &block)
      replace_invitation_account(broker, app, kind) if title == 'Joining table'
      result
    end
  else
    after_invitation_call(app, :establish_invited_table_transport) do
      replace_invitation_account(broker, app, kind)
    end
  end
  result = app.send(:join_table_snapshot, snapshot)
  assert(result.nil?, 'Manual join exposed an old-account successful result')
  assert(broker.cores.fetch(table['__live_session_id']).participants.keys.sort == %w[alice bob], 'Manual join rebound another account')
  assert(gateway.rows['Bob'].none?(&:revoked), 'Manual join completed invitations for an old account') unless stage == :task_delivery
end

# A caller with the old Session name but a different authenticated provider is
# rejected before any membership request, even if invitation metadata matches.
broker, gateway, app, table, invitation = invitation_account_fixture(private_table: true)
replace_invitation_account(broker, app, :endpoint)
assert(app.send(:accept_pending_invitation, invitation).nil?, 'Mismatched authenticated account accepted')
assert(!app.send(:reject_pending_invitation, invitation), 'Mismatched authenticated account rejected')
assert(broker.cores.fetch(table['__live_session_id']).participants.keys == ['alice'], 'Wrong authenticated endpoint acquired membership')
assert(gateway.rows['Bob'].none?(&:revoked), 'Wrong authenticated endpoint revoked notification')

# Completion can be retried from the original account after its earlier native
# membership was accepted. Do not undo that accepted request using table ID.
broker, gateway, app, table, invitation = invitation_account_fixture
original_endpoint = app.transport.instance_variable_get(:@program).live_sessions
establish = app.method(:establish_invited_table_transport)
app.define_singleton_method(:establish_invited_table_transport) do |row|
  result = establish.call(row)
  replace_invitation_account(broker, app, :both)
  result
end
assert(app.send(:accept_pending_invitation, invitation).nil?, 'Initial late result was accepted')
app.define_singleton_method(:establish_invited_table_transport, establish)
$game_room_test_user = 'Bob'
app.transport.instance_variable_get(:@program).live_sessions = original_endpoint
app.send(:accept_pending_invitation, invitation)
assert(gateway.rows['Bob'].all?(&:revoked), 'Original account could not complete its accepted membership')
assert(broker.cores.fetch(table['__live_session_id']).participants.keys.sort == %w[alice bob], 'Retry duplicated or changed membership')

puts 'PASS invitation account completion: public/private, runtime/auth identity, reconnect, role, response, delivery and manual entry'
