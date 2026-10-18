require_relative '../support/consumed_discovery_invitation'

%w[Other Bob].each do |user|
  with_consumed_invitation do |fixture|
    fixture.deliver
    assert_equal(:joined, fixture.join)
    original = fixture.endpoint.sessions.fetch(0)
    old_token = fixture.store.membership_token(41)
    replacement = fixture.build_endpoint(user)
    fixture.program.live_sessions = replacement
    assert(replacement.sessions.empty?, 'Replacement endpoint already had a membership')

    result = fixture.store.join_room(fixture.table, user)
    assert_equal(:joined, result, 'The same account on another endpoint borrowed the old membership')
    assert_equal(1, replacement.sessions.length, 'Successful join did not belong to the current endpoint')
    current = replacement.sessions.fetch(0)
    assert(fixture.store.send(:active_session, 41).equal?(current), 'The store retained its previous endpoint attachment')
    assert(!old_token.equal?(fixture.store.membership_token(41)), 'Replacing an endpoint retained the earlier visit token')
    assert(!original.closed?, 'Joining the current endpoint undid a different accepted membership')
    assert_equal(:already_here, fixture.store.join_room(fixture.table, user), 'Reopening the actual same endpoint repeated a join')
    assert_equal([:join, :join], fixture.calls.map(&:first))

    # A delayed leave callback of the original visit cannot close the new one.
    fixture.endpoint.define_singleton_method(:leave_session) { |_session| true }
    original.leave
    fixture.endpoint.dispatch_events
    assert(fixture.store.send(:active_session, 41).equal?(current) && !current.closed?, 'Old closure removed the replacement endpoint membership')
  end
end

puts 'PASS join endpoint ownership: actual Session membership, same-account replacement, idempotent reopen, stale closure and new visit token'
