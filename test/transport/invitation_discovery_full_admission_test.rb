require_relative '../support/consumed_discovery_invitation'

# Native discovery already consumed the invitation before the application
# counts bots/playing seats. A local capacity rejection leaves that accepted
# membership, but cannot make the consumed invitation pending again.
with_consumed_invitation do |f|
  old = f.deliver.fetch('__native_invitation')
  f.deliver(42, 1, app_id: 92)
  table = f.method(:table)
  f.define_singleton_method(:table) { |id = 41| table.call(id).merge('max_players' => id == 41 ? 1 : 8) }
  f.endpoint.define_singleton_method(:leave_session) do |session|
    f.calls << [:leave, session.id]
    true
  end
  assert_equal(:full, f.join, 'The application must still reject its overfull playing roster')
  assert(old.pending?, 'The handed-out SDK wrapper must retain its native behavior')
  remaining_native = []
  while (item = f.endpoint.next_invitation(timeout: 0))
    remaining_native << item.id
  end
  assert_equal(['native-room-42'], remaining_native, 'Native join did not consume only its own invitation')
  assert(f.endpoint.sessions.empty?, 'Local rejection did not leave its accepted membership')
  assert_equal([92], f.store.pending_invitations.map { |row| row['__id'] },
    'Native-consumed invitation remained pending after local full-room rejection')
  assert_equal([92], f.repo.pending_for('Bob', tables: [f.table, f.table(42)]).map(&:id),
    'A cold repository resurrected the invitation rejected only by local capacity')
  assert_equal([:join, :leave], f.calls.map(&:first), 'Capacity cleanup tried to reject an already consumed invitation')
end

with_consumed_invitation do |f|
  f.deliver
  assert_equal(:joined, f.join)
  replacement = EltenAPI::LiveSessions::Invitation.new(f.endpoint, f.packet)
  assert(replacement.pending?, 'The control must be a distinct pending native wrapper')
  f.store.send(:receive_invitation, replacement, source: f.endpoint)
  assert(f.store.pending_invitations.empty?, 'Same generation reappeared through a newly allocated wrapper')
  f.deliver(41, 2)
  assert_equal([2], f.store.pending_invitations.map { |row| row.fetch('__native_invitation').generation },
    'Consuming one generation removed a genuinely new invitation')
  assert_equal([:join], f.calls.map(&:first))
end

# A missing room projection is not a confirmed local capacity decision. Keep
# the existing closed/uncertain outcome policy rather than broadening cleanup.
with_consumed_invitation do |f|
  f.deliver
  f.store.define_singleton_method(:room_snapshot) { |*_arguments, **_options| nil }
  f.endpoint.define_singleton_method(:leave_session) { |_session| true }
  assert_equal(:closed, f.join)
  assert_equal([91], f.store.pending_invitations.map { |row| row['__id'] }, 'Closed admission was mistaken for confirmed capacity rejection')
end

puts 'PASS consumed discovery invitations: local full-room rejection and new wrappers of the same generation'
