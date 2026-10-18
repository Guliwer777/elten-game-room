require_relative '../support/consumed_discovery_invitation'

# Combine the final capacity-cleanup fix with generation supersession. The
# original invitation was consumed by native join, but a genuinely newer one
# arrived before local admission finished. It must survive the old cleanup.
with_consumed_invitation do |fixture|
  original = fixture.deliver.fetch('__native_invitation')
  fixture.deliver(42, 1, app_id: 92)
  table = fixture.method(:table)
  fixture.define_singleton_method(:table) { |id = 41| table.call(id).merge('max_players' => id == 41 ? 1 : 8) }
  fixture.after_admission = -> { fixture.deliver(41, 2) }
  fixture.endpoint.define_singleton_method(:leave_session) do |session|
    fixture.calls << [:leave, session.id]
    true
  end
  assert_equal(:full, fixture.join)
  pending = fixture.store.pending_invitations
  assert_equal([91, 92], pending.map { |row| row['__id'] }.sort)
  assert_equal(2, pending.find { |row| row['table_id'] == 41 }.fetch('__native_invitation').generation)
  fixture.store.send(:receive_invitation, original, source: fixture.endpoint)
  assert_equal(2, fixture.store.pending_invitations.find { |row| row['table_id'] == 41 }.fetch('__native_invitation').generation,
    'A delayed consumed wrapper replaced the newer invitation after capacity rejection')
  assert_equal([:join, :leave], fixture.calls.map(&:first), 'Capacity/generation cleanup made another server mutation')
end

# Capacity rejection itself performs a native leave. A replacement endpoint
# can already have joined the same room before that old leave returns. Its
# exact membership and invitation cache must not be removed by the old flow.
%w[Other Bob].each do |user|
  with_consumed_invitation do |fixture|
    fixture.deliver
    full = true
    table = fixture.method(:table)
    fixture.define_singleton_method(:table) { |id = 41| table.call(id).merge('max_players' => full ? 1 : 8) }
    replacement = fixture.build_endpoint(user)
    joined = nil
    fixture.endpoint.define_singleton_method(:leave_session) do |session|
      fixture.calls << [:leave, session.id]
      full = false
      fixture.program.live_sessions = replacement
      fixture.deliver(42, 1, app_id: 92, endpoint: replacement)
      assert_equal(:joined, fixture.store.join_room(fixture.table, user))
      joined = replacement.sessions.fetch(0)
      true
    end
    assert_equal(:full, fixture.join)
    assert(joined && !joined.closed?, 'Old full-room cleanup closed the new accepted visit')
    assert(fixture.store.send(:active_session, 41).equal?(joined), 'Old full-room cleanup detached the new accepted visit')
    assert_equal([92], fixture.store.pending_invitations.map { |row| row['__id'] }, 'Old resolution removed a new endpoint invitation')
    assert_equal([:join, :leave, :join], fixture.calls.map(&:first), 'Old cleanup issued an extra leave/accept/reject')
  end
end

# Explicit rejection can also finish after a newer server generation arrives.
# The same resolution helper is used by direct acceptance and discovery.
with_consumed_invitation do |fixture|
  fixture.deliver
  original = fixture.endpoint.method(:discovery_request)
  fixture.endpoint.define_singleton_method(:discovery_request) do |operation, parameters, **options|
    result = original.call(operation, parameters, **options)
    fixture.deliver(41, 2) if operation == :reject
    result
  end
  assert(fixture.store.reject_invitation(table_id: 41, invitation_id: 91))
  pending = fixture.store.pending_invitations
  assert_equal(1, pending.length)
  assert_equal(2, pending.fetch(0).fetch('__native_invitation').generation,
    'Acknowledging the previous rejection discarded its newer replacement')
  assert_equal([:reject], fixture.calls.map(&:first))
end

puts 'PASS invitation convergence: capacity + newer generation, old leave + replacement membership, rejection + late new generation'
