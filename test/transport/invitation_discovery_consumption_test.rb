require_relative '../support/consumed_discovery_invitation'

with_consumed_invitation do |f|
  original = f.deliver.fetch('__native_invitation')
  f.deliver(42, 1, app_id: 92)
  current_repo = f.repo
  accepted = current_repo.pending_for('Bob', tables: [f.table, f.table(42)]).find { |item| item.id == 91 }
  assert_equal(:joined, f.join)
  assert(original.pending?, 'Test must preserve actual SDK handed-out wrapper semantics')
  assert_equal([92], f.store.pending_invitations.map { |row| row['__id'] },
    'Consumed discovery invitation remains in the native cache')
  current_repo.respond(accepted, recipient: 'Bob', response: 'accepted')
  [current_repo, f.repo].each do |repo|
    assert_equal([92], repo.pending_for('Bob', tables: [f.table, f.table(42)]).map(&:id),
      'A cold repository exposed a consumed invitation')
  end
  f.store.send(:receive_invitation, original, source: f.endpoint)
  f.endpoint.send(:receive_invitation, f.packet)
  f.endpoint.dispatch_events
  assert_equal([92], f.store.pending_invitations.map { |row| row['__id'] }, 'Delayed wrapper resurrected after join')
  assert_equal([:join], f.calls.map(&:first), 'Local consumption issued an extra accept or reject')
  assert_equal(:already_here, f.join)
  assert_equal([:join], f.calls.map(&:first), 'Idempotent reopen repeated native acceptance')
end

with_consumed_invitation do |f|
  original = f.deliver.fetch('__native_invitation')
  f.after_admission = -> { f.deliver(41, 2) }
  assert_equal(:joined, f.join)
  newest = f.store.pending_invitations.fetch(0).fetch('__native_invitation')
  assert_equal(2, newest.generation, 'Completing an older join removed a newer generation')
  f.store.send(:receive_invitation, original, source: f.endpoint)
  assert(f.store.pending_invitations.fetch(0).fetch('__native_invitation').equal?(newest),
    'A delayed old callback replaced a later invitation')
  assert(f.store.reject_invitation(table_id: 41, invitation_id: 91), 'Newer invitation was incorrectly tombstoned')
  assert(f.store.pending_invitations.empty?, 'Explicit new-generation response failed to resolve')
end

with_consumed_invitation do |f|
  f.deliver
  f.join_error = EltenAPI::LiveSessions::TimeoutError.new('Unknown join response')
  assert_raises(EltenAPI::LiveSessions::TimeoutError) { f.join }
  assert_equal([91], f.store.pending_invitations.map { |row| row['__id'] }, 'Unknown join discarded retry authority')
  f.join_error = nil
  assert_equal(:joined, f.join)
  assert(f.repo.pending_for('Bob', tables: [f.table]).empty?, 'Confirmed retry retained the old wrapper')
  assert_equal([:join, :join], f.calls.map(&:first))
end

['Other', 'Bob'].each do |user|
  with_consumed_invitation do |f|
    f.deliver
    replacement = f.build_endpoint(user)
    f.after_admission = -> { f.program.live_sessions = replacement }
    assert_equal(:closed, f.join, 'Late old success became current-account admission')
    f.store.pending_invitations # Register the current endpoint, without I/O.
    f.deliver(42, 1, app_id: 92, endpoint: replacement)
    assert_equal([92], f.store.pending_invitations.map { |row| row['__id'] },
      'Old completion consumed the new account or endpoint invitation')
    assert_equal([user], f.store.pending_invitations.map { |row| row['recipient'] }.uniq)
    assert_equal(1, f.endpoint.sessions.size, 'Identity denial discarded the accepted old membership')
    assert(f.store.invitation_account_identity.first.equal?(replacement))
  end
end

[{}, {'method' => 'public'}, {'method' => 'invitation', 'invitation_id' => 'different', 'invitation_generation' => 1},
 {'method' => 'invitation', 'invitation_id' => 'server-41-1', 'invitation_generation' => 2}].each do |context|
  with_consumed_invitation do |f|
    f.deliver
    f.context_override = context
    assert_equal(:joined, f.join)
    assert_equal([91], f.store.pending_invitations.map { |row| row['__id'] },
      'Missing or nonmatching native proof guessed a consumed invitation')
  end
end

with_consumed_invitation do |f|
  f.deliver
  f.deliver(42, 1, app_id: 92)
  assert(f.store.accept_invitation(table_id: 41, invitation_id: 91), 'Direct native acceptance regressed')
  assert_equal([92], f.store.pending_invitations.map { |row| row['__id'] })
end
puts 'PASS discovery invitation consumption: actual SDK cache, cold repo, delayed callback, generations, accounts/endpoints and retry'
