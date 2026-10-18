require_relative '../support/native_room_harness'

h = NativeRoomHarness.new(users: %w[Alice])
append = lambda do |user, kind, text = nil|
  h.as(user) do
    TableActivityRepository.new(server_tables: {}, transport: h.transports.fetch(user))
      .append(table: h.transports.fetch(user).room_snapshot(h.table).fetch(:table), kind: kind, actor: user, message: text)
  end
end
created = append.call('Alice', 'created')
hidden = append.call('Alice', 'chat', 'Before the visitor')
h.add_client('Bob')
assert(h.join('Bob'), 'Visitor cannot join')
joined = append.call('Bob', 'joined')
visible = append.call('Alice', 'chat', 'Visible to the visitor')
h.as('Alice') { h.transports.fetch('Alice').transfer_room_owner(h.table, 'Bob') }

# A completely new repository projects the accepted native log after the
# ownership update; it cannot rely on a cached pre-transfer private cut-off.
cold = TableActivityRepository.new(server_tables: {}, transport: h.transports.fetch('Bob'))
row = h.as('Bob') { h.transports.fetch('Bob').room_snapshot(h.table).fetch(:table) }
before = h.core.entries.map(&:dup)
2.times do
  entries = h.as('Bob') { cold.entries_for(row, viewer: 'bOB') }
  assert(entries.map(&:kind) == %w[joined chat owner_changed] && entries.first.id == joined.id &&
    entries[1].id == visible.id, 'Cold/warm projection exposed pre-visit history or lost the real owner-change event')
end
assert(h.core.entries == before, 'Read-only visitor filtering rewrote the room log')
unfiltered = h.as('Bob') { cold.entries_for(row) }
assert(unfiltered.first(4).map(&:id) == [created.id, hidden.id, joined.id, visible.id] &&
  unfiltered.last.kind == 'owner_changed', 'Scoped read removed retained history from the unfiltered projection')

# Former owner comes back as an observer, then takes ownership again; two
# transfers still cannot move the start of their second visit backwards.
h.as('Alice') { h.transports.fetch('Alice').deactivate_table(table_id: h.table['__id']) }
between = append.call('Bob', 'chat', 'Between visits')
assert(h.join('Alice'), 'Former owner cannot return')
returned = append.call('Alice', 'joined')
h.as('Alice') { h.transports.fetch('Alice').set_observer(h.table, true, actor: 'Alice') }
latest = append.call('Bob', 'chat', 'Current visit')
h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
reader = TableActivityRepository.new(server_tables: {}, transport: h.transports.fetch('Alice'))
row = h.as('Alice') { h.transports.fetch('Alice').room_snapshot(h.table).fetch(:table) }
entries = h.as('Alice') { reader.entries_for(row, viewer: 'Alice') }
assert(entries.first.id == returned.id && entries.any? { |entry| entry.id == latest.id }, 'Returned observer/owner lost current visit')
assert(entries.none? { |entry| entry.id <= between.id }, 'Returned observer/owner recovered earlier visits')
puts 'PASS independent activity cold/warm visit scope, mixed case, observer/owner transfer and immutable raw history'
