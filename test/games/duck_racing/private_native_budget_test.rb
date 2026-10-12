require_relative '../../support/duck_private_round'
require_relative '../../../games/duck_racing_support/wire_budget'
require_relative '../../support/native_room_harness'

include DuckPrivateRoundTest
protocol = PRIVATE_ROUND
budget = GameRoomDuckRacing::WireBudget
actor = 'Łucja長鴨'
h = NativeRoomHarness.new(users: [actor, 'Bob'])
h.start
h.core.stack_entry_bytes = 1536
repository = h.repositories.fetch(actor)
session = repository.snapshot_for(h.session).session
state = private_state(session_id: session.fetch('__id'), round_id: '1', commit_deadline_ms: nil)
vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
trace = input_trace('wiosna', count: 350, kind: 'answer')
trace['actions'].each_with_index { |entry, index| entry['input']['value'] += " #{index}-#{index * 731}" }
counter, limit = 12, 4096
replay = GameRoomGames::Replay.new(accepted_events: [], state: {session_id: state[:session_id],
  bot_controller_epoch: session.fetch('__control_epoch')})
builder = lambda do |page|
  data = {'action' => 'reveal', 'challenge' => 1, 'page' => page, 'revision' => counter,
    'session' => state[:session_id], 'at' => 1791674690000 + counter}
  budget.plan('duck_racing', data, replay: replay, actor: actor, limit: limit)
end
prepared = protocol.prepare(state, seat: 0, user: actor, trace: trace, vault: vault,
  nonce: '7b' * 32, page_builder: builder)
assert(commit_private(state, prepared, 0))
assert(protocol.forfeit(state, seat: 1, reason: :test_other_seat))
assert(protocol.close_commits(state, now_ms: 2_000))

# Accept an out-of-order page under the old budget. A smaller grant must
# split only its surrounding gaps, never overlap or lose this accepted page.
last = prepared.reveal_pages.last
assert(protocol.accept_reveal_page(state, seat: 0, page: last, now_ms: 2_001))
limit = 1536
replay.state[:bot_controller_epoch] = 'e' * 64
replay.accepted_events << {'sequence' => 9_999_998}
counter = 999_999_999
recovered = protocol.recover(state, seat: 0, user: actor, vault: vault, page_builder: builder)
assert_equal(prepared.envelope.commitment, recovered.envelope.commitment)
assert(recovered.offsets.include?(last['offset']))
assert_equal(last, recovered.reveal_page(recovered.offsets.index(last['offset'])))
assert(recovered.offsets.length > prepared.offsets.length)
recovered.reveal_pages.each do |page|
  next if page['offset'] == last['offset']
  assert(page['offset'] + protocol.reveal_page_size(page) <= last['offset'])
end

# Send the remaining outer Duck plans through the real shared Writer. For
# this transport trial the actual epoch stays the session's epoch; first
# budget using the longer epoch was deliberately conservative.
replay.state[:bot_controller_epoch] = session.fetch('__control_epoch')
accepted_offsets = [last['offset']]
now = 2_002
until state[:phase] == :finished
  recovered = protocol.recover(state, seat: 0, user: actor, vault: vault, page_builder: builder)
  page = protocol.next_reveal_page(state, recovered)
  plan = builder.call(page)
  h.broker.automatic_delivery = false
  h.view(actor).fail_next_push = :after if accepted_offsets.length == 1
  begin
    h.write(actor, plan.events)
  rescue EltenAPI::LiveSessions::TimeoutError
    entries = h.core.entries.length
    h.as(actor) { h.transports.fetch(actor).reconcile(h.table['__id']) }
    assert_equal(entries, h.core.entries.length, 'Lost acknowledgement duplicated a native page')
  end
  h.broker.deliver(duplicate: true)
  h.broker.automatic_delivery = true
  assert(protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: now += 1))
  assert(!accepted_offsets.include?(page['offset']), 'An accepted offset was selected twice')
  accepted_offsets << page['offset']
  counter += 1
end
assert_equal(trace['actions'].map { |entry| [entry['at'], entry['input']] }, state[:reveals][0]['trace'])
assert_equal(trace['finished_at'], state[:reveals][0]['elapsed_ms'])
packets = h.core.entries.select { |entry| entry.dig('packet', 'kind') == 'game_action' }
assert(packets.all? { |entry| JSON.generate(entry.fetch('packet')).bytesize <= 1536 })
h.assert_converged('outer Duck pages after lost acknowledgement')
h.as(actor) { h.view(actor).close }
puts "PASS Duck native pagination: #{accepted_offsets.length} pages, changed byte grant/revision/epoch, Unicode, out-of-order recovery and lost acknowledgement"
