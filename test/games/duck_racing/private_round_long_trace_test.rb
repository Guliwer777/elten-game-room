require_relative "../../support/duck_private_round"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/audio_challenges"

include DuckPrivateRoundTest
protocol = PRIVATE_ROUND
audio = GameRoomDuckRacing::AudioChallenges

# Real Simon input, well beyond 30 tones. Both players finish by a deliberate
# wrong key, not an invented terminal score or a hidden maximum sequence size.
model = audio.start("simon", seats: [0, 1], seed: 2026, now_ms: 0)
traces = {}
{0 => 42, 1 => 35}.each do |seat, goal|
  actions, now, press = [], 0, 0
  record = lambda do |input|
    assert(audio.submit(model, seat: seat, action: input, now_ms: now), "Rejected generated Simon action")
    actions << {"at" => now, "input" => input.to_h { |key, value| [key.to_s, value.is_a?(Symbol) ? value.to_s : value] }}
  end
  loop do
    playback = audio.stimulus(model, seat: seat)
    events = playback.fetch(:events)
    now = playback.fetch(:requested_ms) + events.last.fetch(:offset_ms) + events.last.fetch(:duration_ms) + 10
    record.call(kind: :playback_finished, playback_id: playback.fetch(:id))
    if events.length > goal
      now += 100
      press += 1
      record.call(kind: :tone, value: events.first.fetch(:tone) % 5 + 1, press_id: press)
      break
    end
    events.each do |sound|
      now += 100
      press += 1
      record.call(kind: :tone, value: sound.fetch(:tone), press_id: press)
    end
  end
  traces[seat] = {"actions" => actions, "finished_at" => now}
end
assert_equal(true, model[:finished])
assert_equal({0 => 42, 1 => 35}, model[:scores])
assert(traces[0]["actions"].length > 900)
state = private_state(commit_deadline_ms: nil)
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
page_builder = private_page_builder(state)
prepared = traces.to_h { |seat, trace| [seat, prepare_private(state, seat, trace, vault: vault, page_builder: page_builder)] }
prepared.each do |seat, answer|
  assert(answer.reveal_plans.length > 1, "Long trace was silently limited or not paged")
  assert(commit_private(state, answer, seat, now_ms: traces.values.map { |trace| trace["finished_at"] }.max + 2_000))
end
reveal_start = traces.values.map { |trace| trace["finished_at"] }.max + 2_100
assert(protocol.close_commits(state, now_ms: reveal_start))
assert_equal(nil, protocol.next_reveal_plan(private_state, prepared[0]))

# Out-of-order complete pages are buffered; missing pages remain resumable.
last_plan = prepared[0].reveal_plans.last
assert(deliver_private(state, last_plan, 0, now_ms: reveal_start + 1))
saved_deadline = state[:reveal_deadlines][0]
rejected_unchanged(state) { deliver_private(state, last_plan, 0, now_ms: reveal_start + 100) }
assert_equal(saved_deadline, state[:reveal_deadlines][0])
fresh_vault = HiddenSubmissions::Vault.new(storage)
recovered = protocol.recover(state, seat: 0, user: "account-0", vault: fresh_vault, page_builder: page_builder)
assert_equal(prepared[0].envelope.commitment, recovered.envelope.commitment)
assert_equal(recovered.reveal_plans.first, protocol.next_reveal_plan(state, recovered))
assert_equal(false, state[:reveals].key?(0), "A partial trace was prematurely published")
assert_raises(protocol::NotResolved) { protocol.replay(state, adapter: DuckPrivateRoundTest::CaptureReplay.new) }

clock = reveal_start + 200
prepared[1].reveal_plans.reverse.each do |plan|
  assert(deliver_private(state, plan, 1, now_ms: clock))
  clock += 1
end
while (plan = protocol.next_reveal_plan(state, recovered))
  assert(deliver_private(state, plan, 0, now_ms: clock))
  clock += 1
end
assert_equal(:finished, state[:phase])

# An adapter verifies the exact canonical actions using the real model.
# Symbol conversion is restricted to fixed keys/kinds, never arbitrary input.
verifier = Object.new
def verifier.replay(traces:, forfeits:)
  raise "Unexpected forfeit" unless forfeits.empty?
  model = GameRoomDuckRacing::AudioChallenges
  state = model.start("simon", seats: traces.keys.sort, seed: 2026, now_ms: 0)
  keys = %w[kind value press_id playback_id].to_h { |name| [name, name.to_sym] }
  kinds = %w[tone playback_finished].to_h { |name| [name, name.to_sym] }
  traces.each do |seat, trace|
    trace.fetch("actions").each do |entry|
      action = entry.fetch("input").to_h { |key, value| [keys.fetch(key), key == "kind" ? kinds.fetch(value) : value] }
      raise "Replay rejected private input" unless model.submit(state, seat: seat, action: action, now_ms: entry.fetch("at"))
    end
    model.expire(state, now_ms: trace.fetch("finished_at"))
  end
  raise "Replay did not complete" unless state[:finished]
  state[:scores]
end
assert_equal({0 => 42, 1 => 35}, protocol.replay(state, adapter: verifier))
capture = DuckPrivateRoundTest::CaptureReplay.new
protocol.replay(state, adapter: capture)
assert_equal(traces, capture.received[:traces], "Paging changed, truncated or invented private input")

# Capacity is supplied by the actual adapter, not a second guessed stack
# constant. Preflight errors preserve the full private payload but return no
# committable command, do not fake a loss, and can be cancelled explicitly.
state = private_state(commit_deadline_ms: nil)
before = Marshal.dump(state)
needed = prepared[0].records_needed
assert_raises(protocol::CapacityError) { prepare_private(state, 0, traces[0], available_records: needed - 1, page_builder: page_builder) }
assert_equal(before, Marshal.dump(state))
assert_equal({}, state[:forfeits])
exact = prepare_private(state, 0, traces[0], available_records: needed, page_builder: page_builder)
assert_equal(needed, exact.records_needed)
assert_equal(traces[0]["actions"].length, exact.envelope.payload["trace"].length)
assert_raises(ArgumentError) { prepare_private(state, 0, traces[0], available_records: -1) }
assert_raises(protocol::CapacityError) do
  prepare_private(state, 0, input_trace("x" * GameRoomDuckRacing::PrivateTraceStream::MAX_EXPANDED_BYTES, kind: "answer"))
end
assert_equal(before, Marshal.dump(state))
assert(protocol.cancel(state, reason: "insufficient remaining transport capacity"))
calls = capture.calls
assert_raises(protocol::Cancelled) { protocol.replay(state, adapter: capture) }
assert_equal(calls, capture.calls)
assert_equal({}, state[:forfeits])

# Partial-page validation, identity, overlap and independent idle deadlines.
state = private_state
prepared = [0, 1].to_h do |seat|
  [seat, prepare_private(state, seat, input_trace("word", count: 350, kind: "answer"), page_builder: private_page_builder(state, max_bytes: 64))]
end
assert(prepared.values.all? { |entry| entry.reveal_pages.length > 1 })
prepared.each { |seat, answer| assert(commit_private(state, answer, seat)) }
assert(protocol.close_commits(state, now_ms: 2_000))
first_page = private_pages(state, prepared[0].reveal_plans.first, 0).first.first
assert(protocol.accept_reveal_page(state, seat: 0, page: first_page, now_ms: 6_500))
assert_equal(11_500, state[:reveal_deadlines][0])
assert_equal(7_000, state[:reveal_deadlines][1])
original_data = first_page["data"].dup
first_page["data"].replace("locally mutated")
assert_equal(original_data, state[:pages][0][0]["data"], "Page state shares an incoming mutable value")
second_page = private_pages(state, prepared[0].reveal_plans[1], 0).first.first
[
  second_page.merge("codec" => "unknown"), second_page.merge("unpacked_bytes" => second_page["unpacked_bytes"] + 1),
  second_page.merge("total" => second_page["total"] + 1), second_page.merge("offset" => 32)
].each do |bad|
  rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: bad, now_ms: 6_600) }
end
rejected_unchanged(state) { deliver_private(state, prepared[0].reveal_plans.first, 0, now_ms: 6_999) }
assert(protocol.expire_reveals(state, now_ms: 7_000))
assert_equal({1 => :reveal_timeout}, state[:forfeits])
assert_equal(:revealing, state[:phase])
prepared[0].reveal_plans.drop(1).each { |plan| assert(deliver_private(state, plan, 0, now_ms: 7_500)) }
protocol.replay(state, adapter: capture)
assert_equal(350, capture.received[:traces][0]["actions"].length)
assert_equal({1 => :reveal_timeout}, capture.received[:forfeits])
assert_equal([0], capture.received[:traces].keys)

# The shared codec ignores incomplete/corrupt/cross-author atomic batches
# and pages belonging to another round. No decoder is copied into the game.
events = private_events(prepared[0].reveal_plans.first, 0)
assert(events.length > 1)
bad_actor = Marshal.load(Marshal.dump(events))
bad_actor[1]["author"] = 1
bad_digest = Marshal.load(Marshal.dump(events))
bad_digest[0]["value"] = bad_digest[0]["value"].sub(/\.[0-9a-f]{10}\./, ".0000000000.")
[events.drop(1), events[0...-1], bad_actor, bad_digest].each do |bad|
  assert_equal([], protocol.each_reveal_page(state, events: bad, repository: REPOSITORY, session: nil).to_a)
end
other = private_state(round_id: "new-round")
assert_equal([], protocol.each_reveal_page(other, events: events, repository: REPOSITORY, session: nil).to_a)

puts "PASS Duck Racing private long traces: real Simon 42/35 tones, 900+ inputs, paged recovery, atomic framing, capacity cancellation and per-seat timeout"
