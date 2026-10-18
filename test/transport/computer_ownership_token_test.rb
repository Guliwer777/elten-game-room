require_relative '../support/room_interface'
require_relative '../support/native_room_harness'

h = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: %w[Alice Bob])
transport = h.transports.fetch('Alice')
view = h.view('Alice')
membership = transport.membership_token(h.table)
original = transport.ownership_token(h.table)
assert(original, 'An active visit has no ownership token')
calls = view.calls.dup
100.times { assert(transport.ownership_token(h.table).equal?(original), 'Reading ownership changed its token') }
assert(view.calls == calls, 'Reading the ownership token performed I/O')
assert(transport.ownership_token(-1).nil?, 'Unknown table acquired an ownership token')

context = -> {
  {table_id: h.table.fetch('__id'), session_id: nil, actor: 'Alice', owner: h.core.owner,
    membership: transport.membership_token(h.table), ownership: transport.ownership_token(h.table)}
}
computer = GameRoomUI::ComputerChangeBuffer.new
assert(computer.enqueue(:add_bot, **context.call), 'Could not enqueue before owner transfer')
chat = GameRoomUI::ChatSendBuffer.new
control = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new).chat
control.set_text('A draft belongs to the visit, not to its host')
assert(chat.enqueue(control, message: control.text, session_id: nil, table: h.table,
  actor: 'Alice', membership: membership) == :queued, 'Could not enqueue the ordinary chat draft')

h.as('Alice') { transport.transfer_room_owner(h.table, 'Bob') }
transferred = transport.ownership_token(h.table)
assert(!transferred.equal?(original), 'A real transfer did not change the ownership token')
h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
assert(!transport.ownership_token(h.table).equal?(transferred), 'A second real transfer reused the token')
assert(transport.membership_token(h.table).equal?(membership), 'Changing host invalidated unrelated visit input')
assert(computer.take(**context.call).nil?, 'An old computer intention survived A -> B -> A')
assert(chat.pending?(table_id: h.table.fetch('__id'), session_id: nil, actor: 'Alice', membership: membership),
  'Changing host discarded an unrelated chat intention')

# The host queues registered callbacks for delivery. Keep the exact callback
# from the old native Session, then deliver it only after a genuine rejoin.
old_callbacks = view.instance_variable_get(:@owner_callbacks).dup
assert(!old_callbacks.empty?, 'The actual store did not register an owner callback')
view.leave
assert(h.join('Alice'), 'The native rejoin failed')
h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
fresh_view = h.view('Alice')
assert(!fresh_view.equal?(view), 'Rejoin did not create a new native Session')
fresh_membership = transport.membership_token(h.table)
fresh_ownership = transport.ownership_token(h.table)
assert(!fresh_membership.equal?(membership), 'Rejoin reused the old attachment')
transport.consume_table_change(h.table.fetch('__id'))
assert(computer.enqueue(:add_bot, **context.call), 'Could not enqueue a new visit intention')
calls = fresh_view.calls.dup
old_callbacks.each { |callback| callback.call(view.owner, h.view('Bob').owner) }
assert(transport.ownership_token(h.table).equal?(fresh_ownership), 'A stale owner callback invalidated the new visit')
assert(transport.membership_token(h.table).equal?(fresh_membership), 'A stale owner callback replaced membership')
assert(!transport.consume_table_change(h.table.fetch('__id')), 'A stale owner callback woke the new table')
assert(fresh_view.calls == calls, 'A stale owner callback performed I/O')
assert(computer.take(**context.call) == [:add_bot, nil], 'A stale callback discarded a valid new intention')

assert(computer.enqueue(:add_bot, **context.call), 'Could not enqueue before the new transfer')
h.as('Alice') { transport.transfer_room_owner(h.table, 'Bob') }
assert(!transport.ownership_token(h.table).equal?(fresh_ownership), 'The current visit callback was ignored')
assert(computer.take(**context.call).nil?, 'The current owner change retained stale input')
assert(transport.consume_table_change(h.table.fetch('__id')), 'The real owner change did not wake the table')

fresh_view.leave
transport.consume_table_change(h.table.fetch('__id'))
old_callbacks.each { |callback| callback.call(nil, nil) }
assert(transport.ownership_token(h.table).nil?, 'A late callback resurrected closed membership')
assert(!transport.consume_table_change(h.table.fetch('__id')), 'A late callback woke a closed visit')

# Account-race cleanup can forget a local attachment while its original native
# endpoint retains the accepted membership. A later ordinary current-room read
# may attach that exact Session again: the old closure must still be ignored.
recovered = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: %w[Alice Bob])
transport = recovered.transports.fetch('Alice')
view = recovered.view('Alice')
old_callbacks = view.instance_variable_get(:@owner_callbacks).dup
membership = transport.membership_token(recovered.table)
store = transport.instance_variable_get(:@live_store)
store.send(:forget_joined_session, recovered.table.fetch('__id'), view)
row = transport.current_room('Alice')
assert(row && row.fetch('__id') == recovered.table.fetch('__id'), 'The retained native room was not recovered')
assert(recovered.view('Alice').equal?(view), 'The attachment probe replaced its native Session')
assert(!transport.membership_token(row).equal?(membership), 'Recovery reused the old attachment')
ownership = transport.ownership_token(row)
transport.consume_table_change(row.fetch('__id'))
calls = view.calls.dup
old_callbacks.each { |callback| callback.call(nil, nil) }
assert(transport.ownership_token(row).equal?(ownership), 'An old same-Session attachment changed current ownership')
assert(!transport.consume_table_change(row.fetch('__id')), 'An old same-Session attachment woke the current table')
assert(view.calls == calls, 'An old same-Session callback performed I/O')
recovered.as('Alice') { transport.transfer_room_owner(row, 'Bob') }
assert(!transport.ownership_token(row).equal?(ownership), 'The recovered current attachment ignored its owner change')
puts 'PASS ownership token: native transfers, A-B-A, local reads, unchanged chat membership, late old-visit/same-Session callbacks and closed visits'
