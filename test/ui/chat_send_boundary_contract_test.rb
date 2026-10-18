require_relative '../support/background_help_game_screen'

h = NativeRoomHarness.new(game: GameRoomGames::FourInARow.new, users: %w[Alice Bob])
h.start
transport = h.transports.fetch('Bob')
repository = TableActivityRepository.new(server_tables: Object.new, transport: transport)
remote = TableActivityRepository.new(server_tables: Object.new, transport: h.transports.fetch('Alice'))
chat = GameSurfaces::RefreshAwareEditBox.new('Chat')
buffer = GameRoomUI::ChatSendBuffer.new
context = lambda do
  {table_id: h.table.fetch('__id'), session_id: h.session.fetch('__id'), actor: 'Bob',
    membership: transport.membership_token(h.table.fetch('__id'))}
end
enqueue = lambda do |text = chat.text|
  buffer.enqueue(chat, message: text, table: h.table, **context.call.reject { |key, _| key == :table_id })
end
write = lambda do |intent|
  h.as('Bob') do
    repository.append(table: intent.table, kind: 'chat', actor: 'Bob', message: intent.message, **intent.write_options)
  end
end

chat.set_text('first')
assert(enqueue.call == :queued && enqueue.call == :duplicate, 'Repeated Enter changed a captured generation')
first = buffer.take(**context.call)
chat.set_text('second')
assert(enqueue.call == :queued, 'A second draft cannot wait behind the sending one')
chat.set_text('third, not admitted')
assert(enqueue.call == :full, 'The bounded one-message waiting slot became an unbounded outbox')
assert(!first.receipt.clear_if_current(chat, session_id: h.session['__id']), 'An old receipt erased newer text')
buffer.complete(first, success: true)
second = buffer.take(**context.call)
assert(first.message == 'first' && second.message == 'second', 'Editing or overflow replaced captured messages')
buffer.complete(second, success: true)
assert(!buffer.pending?(**context.call) && chat.text == 'third, not admitted', 'An unadmitted draft was sent or discarded')

# Lost HTTP reply with no realtime callback: no automatic retry, but a deliberate
# second Enter uses the native deduplication identity rather than a new message.
chat.set_text('lost reply without callback')
assert(enqueue.call == :queued, 'Uncertain-write setup failed')
uncertain = buffer.take(**context.call)
h.broker.automatic_delivery = false
view = h.view('Bob')
view.fail_next_push = :after
begin
  write.call(uncertain)
  raise 'The fixture did not lose the native acknowledgement'
rescue EltenAPI::LiveSessions::TimeoutError
end
buffer.complete(uncertain, success: false)
assert(!buffer.pending?(**context.call), 'An uncertain write was retried without another user action')
assert(chat.text == uncertain.message, 'A failed acknowledgement cleared the draft')
assert(enqueue.call == :queued, 'Manual retry was not admitted')
retried = buffer.take(**context.call)
assert(retried.equal?(uncertain), 'Manual retry changed the original authenticated operation identity')
written = write.call(retried)
assert(written && written.message == uncertain.message, 'Native deduplication did not return the accepted chat')
attempts = view.instance_variable_get(:@push_attempts).last(2).map(&:first)
assert(attempts.length == 2 && attempts.uniq == [uncertain.message_id], 'The retry sent a different UUID')
buffer.complete(retried, success: true)
assert(retried.receipt.clear_if_current(chat, session_id: h.session['__id']), 'Confirmed retry did not clear its unchanged draft')
h.broker.automatic_delivery = true
h.broker.deliver
assert(remote.entries_for(h.table).count { |row| row.kind == 'chat' && row.message == uncertain.message } == 1,
  'The recipient received a duplicate after an uncertain write')

# If the native callback arrives after the error but before manual retry, the
# existing confirmed receipt must avoid even another network push.
chat.set_text('late callback confirms the write')
enqueue.call
late = buffer.take(**context.call)
h.broker.automatic_delivery = false
view.fail_next_push = :after
begin
  write.call(late)
  raise 'The late-callback fixture did not lose its acknowledgement'
rescue EltenAPI::LiveSessions::TimeoutError
end
buffer.complete(late, success: false)
h.broker.deliver
before_pushes = view.instance_variable_get(:@push_attempts).length
enqueue.call
late_retry = buffer.take(**context.call)
assert(write.call(late_retry), 'A confirmed late callback was not reused')
assert(view.instance_variable_get(:@push_attempts).length == before_pushes, 'A confirmed retry still performed another push')
buffer.complete(late_retry, success: true)
h.broker.automatic_delivery = true
h.broker.deliver

# Each context boundary independently invalidates the waiting slot without
# pretending that its unsubmitted editor contents were sent successfully.
changes = [
  ->(value) { value.merge(table_id: value[:table_id] + 1) },
  ->(value) { value.merge(session_id: value[:session_id] + 1) },
  ->(value) { value.merge(actor: 'Alice') },
  ->(value) { value.merge(membership: Object.new) }
]
changes.each_with_index do |change, index|
  chat.set_text("boundary draft #{index}")
  assert(enqueue.call == :queued, 'Boundary setup failed')
  assert(!buffer.pending?(**change.call(context.call)), 'Stale queued chat survived its table/session/account/membership boundary')
  assert(chat.text == "boundary draft #{index}", 'Dropping a stale intention erased editor text')
end

# Rejoining the very same room keeps numeric IDs but changes membership. Check
# the actual writer guard as well as the buffer's pure predicate.
chat.set_text('do not send from my earlier visit')
enqueue.call
previous_visit = buffer.take(**context.call)
lobby = LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Bob')), transport: transport, server_tables: Object.new)
h.as('Bob') { assert(lobby.leave_table(h.table, 'Bob') == :left, 'Could not leave the test membership') }
assert(h.join('Bob'), 'Could not rejoin the same native room')
assert(!previous_visit.membership.equal?(context.call[:membership]), 'Rejoin reused the old membership token')
assert(write.call(previous_visit).nil?, 'The writer sent an old-visit message after rejoining')
buffer.complete(previous_visit, success: false)
enqueue.call
new_visit = buffer.take(**context.call)
assert(new_visit.message_id != previous_visit.message_id, 'A new visit reused the failed previous-visit operation')
buffer.complete(new_visit, success: true)

chat.set_text('do not send into the next game')
enqueue.call
previous_match = buffer.take(**context.call)
h.start
assert(write.call(previous_match).nil?, 'The native writer sent an old-match message after the next game started')
buffer.complete(previous_match, success: false)
buffer.clear
assert(!buffer.pending?(**context.call), 'Closing a buffer retained a send intention')

puts 'PASS chat boundaries: bounded immutable drafts, deliberate same-UUID retries, late callback without push, native rejoin/rematch rejection and identity isolation'
