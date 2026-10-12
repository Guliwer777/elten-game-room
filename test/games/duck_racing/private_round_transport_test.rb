require_relative "../../support/duck_private_round"
require_relative "../../support/native_room_harness"

include DuckPrivateRoundTest
protocol = PRIVATE_ROUND
harness = NativeRoomHarness.new(users: %w[Alice Bob])
harness.start
state = protocol.start(session_id: harness.session.fetch("__id"), round_id: "challenge-1", seats: [0, 1],
  started_at_ms: 1_000, commit_deadline_ms: 20_000, reveal_timeout_ms: 5_000)
traces = {0 => input_trace("rock"), 1 => input_trace("scissors")}
prepared = traces.to_h { |seat, trace| [seat, prepare_private(state, seat, trace)] }

prepared.each do |seat, submission|
  before = harness.core.entries.length
  harness.write(harness.users.fetch(seat), submission.commit_plan.events)
  assert_equal(before + 1, harness.core.entries.length, "One commit consumed several stack records")
end
repository = harness.repositories.fetch("Alice")
harness.events("Alice").each do |event|
  next unless event.fetch("action") == protocol::COMMIT_ACTION
  seat = harness.users.index(repository.actor_of(event, harness.session))
  assert(protocol.accept_commit(state, seat: seat, value: event.fetch("value"), now_ms: 2_000))
end
assert(protocol.close_commits(state, now_ms: 2_000))

# The first page is persisted but its acknowledgement is lost. The ordinary
# store reconciles that same UUID; no second private write loop is introduced.
harness.broker.automatic_delivery = false
harness.view("Alice").fail_next_push = :after
before = harness.core.entries.length
assert_raises(EltenAPI::LiveSessions::TimeoutError) { harness.write("Alice", prepared[0].reveal_plans.first.events) }
assert_equal(before + 1, harness.core.entries.length)
pushes = harness.view("Alice").calls[:push]
harness.as("Alice") { harness.transports.fetch("Alice").reconcile(harness.table.fetch("__id")) }
assert_equal(pushes, harness.view("Alice").calls[:push], "Lost acknowledgement caused a duplicated reveal")
harness.broker.deliver(duplicate: true)
harness.broker.automatic_delivery = true
harness.write("Bob", prepared[1].reveal_plans.first.events)

# Both clients replay the same authenticated stack and converge. Duplicated
# delivery does not repeat a commitment, reveal or downstream settlement.
states = harness.users.map do |user|
  local = protocol.start(session_id: harness.session.fetch("__id"), round_id: "challenge-1", seats: [0, 1],
    started_at_ms: 1_000, commit_deadline_ms: 20_000, reveal_timeout_ms: 5_000)
  repo = harness.repositories.fetch(user)
  events = harness.events(user)
  events.each do |event|
    next unless event.fetch("action") == protocol::COMMIT_ACTION
    seat = harness.users.index(repo.actor_of(event, harness.session))
    assert(protocol.accept_commit(local, seat: seat, value: event.fetch("value"), now_ms: 2_000))
  end
  assert(protocol.close_commits(local, now_ms: 2_000))
  protocol.each_reveal_page(local, events: events, repository: repo, session: harness.session) do |page, actor, _parts|
    assert(protocol.accept_reveal_page(local, seat: harness.users.index(actor), page: page, now_ms: 2_100))
  end
  assert_equal(:finished, local[:phase])
  capture = DuckPrivateRoundTest::CaptureReplay.new
  protocol.replay(local, adapter: capture)
  assert_equal({traces: traces, forfeits: {}}, capture.received)
  local
end
assert_equal(states[0], states[1])

# Fifty fragmented EventCommands are still ONE ordinary native game_action
# record. ARCHIVE_EVENTS_PER_RECORD=10 belongs to saved-archive restoration;
# it must not be mistaken for the cost of a current action plan.
random_text = Base64.strict_encode64(Random.new(42).bytes(3_000))
commands = nil
(1_500..3_000).step(10) do |length|
  candidate = GameRoomActionPayload.commands("duck_payload", {"value" => random_text[0, length]})
  if candidate.length == 50
    commands = candidate
    break
  end
end
assert(commands && commands.length == 50, "Could not create a fifty-fragment transport fixture")
before = harness.core.entries.length
pushes = harness.view("Alice").calls[:push]
harness.write("Alice", commands)
assert_equal(before + 1, harness.core.entries.length)
assert_equal(pushes + 1, harness.view("Alice").calls[:push])
assert_equal(50, harness.core.entries.last.fetch("packet").fetch("data").fetch("events").length)
harness.assert_converged("private commit/reveal and fifty-command batch")

puts "PASS Duck Racing private native transport: real Writer, two account projections, lost acknowledgement, deduplication and one record per atomic plan"
