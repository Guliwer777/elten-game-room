require "tmpdir"
require_relative "../../support/duck_private_round"
require_relative "../../support/hidden_submission_files"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/numeric_challenges"

include DuckPrivateRoundTest
protocol = PRIVATE_ROUND

# Integration example: persist -> commit -> close -> atomic reveal pages ->
# replay the real model. The production owner supplies authorized seats and
# its normal executor; the protocol starts no worker, clock or network call.
state = private_state
traces = {0 => input_trace("rock"), 1 => input_trace("scissors")}
prepared = traces.to_h { |seat, trace| [seat, prepare_private(state, seat, trace)] }
prepared.each_value do |submission|
  assert_equal(submission.commit_plan.events.first.value, submission.commit_value)
  submission.commit_value.clear
  assert(!submission.commit_value.empty?, "Commit-value helper shares mutable data")
  assert_equal(submission.reveal_plans.length, submission.reveal_pages.length)
  submission.reveal_pages.each_with_index do |page, index|
    assert_equal(page, private_pages(state, submission.reveal_plans[index], page.fetch("seat")).first.first)
    wrapped = {"kind" => "reveal", "challenge" => state[:round_id], "page" => page}
    commands = GameRoomActionPayload.commands("duck_challenge", wrapped)
    GameRoomEventProtocol.validate_commands!(commands)
  end
  submission.reveal_page(0)["data"].clear
  assert(!submission.reveal_page(0)["data"].empty?)
  assert_raises(IndexError) { submission.reveal_page(-1) }
  assert_raises(IndexError) { submission.reveal_page(100) }
end
prepared.each { |seat, submission| assert(commit_private(state, submission, seat)) }
assert_equal(nil, protocol.next_reveal_plan(state, prepared[0]))
assert_equal(nil, protocol.next_reveal_page(state, prepared[0]))
assert(protocol.close_commits(state, now_ms: 2_000))
assert_equal(prepared[0].reveal_page(0), protocol.next_reveal_page(state, prepared[0]))
assert_raises(protocol::NotResolved) { protocol.replay(state, adapter: DuckPrivateRoundTest::CaptureReplay.new) }
prepared.each do |seat, submission|
  while (plan = protocol.next_reveal_plan(state, submission))
    assert(deliver_private(state, plan, seat))
  end
end
assert_equal(:finished, state[:phase])

verifier = Object.new
def verifier.replay(traces:, forfeits:)
  raise "Unexpected protocol forfeit" unless forfeits.empty?
  model = GameRoomDuckRacing::NumericChallenges
  replay = model.start("rock_paper_scissors", seats: traces.keys.sort, seed: 712, now_ms: 0)
  traces.each do |seat, trace|
    trace.fetch("actions").each do |entry|
      raise "Invalid disclosed action" unless model.submit(replay, seat: seat, action: entry.fetch("input"), now_ms: entry.fetch("at"))
    end
  end
  raise "Incomplete reconstructed challenge" unless replay[:finished]
  replay
end
result = protocol.replay(state, adapter: verifier)
assert_equal(0, result[:outcome][:winner])
assert_equal({0 => "rock", 1 => "scissors"}, result[:scores])
capture = DuckPrivateRoundTest::CaptureReplay.new
protocol.replay(state, adapter: capture)
assert_equal({traces: traces, forfeits: {}}, capture.received)
capture.received[:traces][0]["actions"][0]["input"]["value"].replace("paper")
assert_equal("rock", state[:reveals][0]["trace"][0][1]["value"], "Replay adapter mutated the protocol")
projection = protocol.public_view(state)
assert_equal([:cancellation, :forfeits, :phase, :revealed, :round_id, :seats, :submitted], projection.keys.sort)
projection[:seats].clear
projection[:round_id].replace("changed")
assert_equal([0, 1], state[:seats])
assert_equal("match-1/challenge-2", state[:round_id])

# All non-terminal rejection paths leave the replicated state unchanged.
state = private_state
first = prepare_private(state, 0, input_trace)
other_round = private_state(round_id: "other-round")
other_session = private_state(session_id: 92)
[other_round, other_session].each do |other|
  rejected_unchanged(other) { protocol.accept_commit(other, seat: 0, value: first.commit_plan.events.first.value, now_ms: 2_000) }
end
[-1, 999, 50_000, 50_001, 2_000.0].each do |time|
  rejected_unchanged(state) { protocol.accept_commit(state, seat: 0, value: first.commit_plan.events.first.value, now_ms: time) }
end
[nil, "", "0" * 64, first.commit_plan.events.first.value + "x"].each do |value|
  rejected_unchanged(state) { protocol.accept_commit(state, seat: 0, value: value, now_ms: 2_000) }
end
rejected_unchanged(state) { protocol.accept_commit(state, seat: 9, value: first.commit_plan.events.first.value, now_ms: 2_000) }
assert(commit_private(state, first, 0))
rejected_unchanged(state) { commit_private(state, first, 0) }
rejected_unchanged(state) { protocol.close_commits(state, now_ms: 49_999) }
assert(protocol.close_commits(state, now_ms: 50_000))
assert_equal({1 => :commit_timeout}, state[:forfeits])
assert_equal(55_000, state[:reveal_deadlines][0])
page = private_pages(state, first.reveal_plans.first, 0).first.first
bad_pages = [nil, {}, page.merge("round" => "old"), page.merge("session" => 92), page.merge("seat" => 1),
  page.merge("nonce" => "f" * 64), page.merge("elapsed_ms" => -1), page.merge("elapsed_ms" => 100.0),
  page.merge("total" => -1), page.merge("offset" => -1), page.merge("offset" => 99),
  page.merge("score" => 9_999), page.merge(:unknown => true), page.merge("trace" => nil),
  page.merge("trace" => [[100, {"kind" => "choose", "value" => "paper", "press_id" => 1}]])]
bad_pages.each do |bad|
  rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: bad, now_ms: 50_001) }
end
rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: 49_999) }
rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: 55_000) }
assert(protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: 54_999))
page["data"].replace("changed")
assert_equal("rock", state[:reveals][0]["trace"][0][1]["value"])
rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: 54_999) }
rejected_unchanged(state) { protocol.expire_reveals(state, now_ms: 99_000) }
rejected_unchanged(state) { protocol.forfeit(state, seat: 0, reason: :disconnect) }
protocol.replay(state, adapter: capture)
assert_equal({1 => :commit_timeout}, capture.received[:forfeits])
assert_equal([0], capture.received[:traces].keys)

# Bad local traces are errors, not attempts, forfeits or forged scores.
state = private_state
invalid = [nil, [], {}, input_trace.merge("score" => 1), input_trace.merge(:extra => 1),
  input_trace.merge("finished_at" => -1), input_trace.merge("finished_at" => 99),
  {"actions" => [nil], "finished_at" => 1},
  {"actions" => [{"at" => 1, "input" => {kind: :choose, value: "rock", score: 9}}], "finished_at" => 1},
  {"actions" => [{"at" => 1, "input" => {kind: :choose, "kind" => "choose"}}], "finished_at" => 1},
  {"actions" => [{"at" => 1, "input" => {kind: :choose, repeat: true}}], "finished_at" => 1},
  {"actions" => [{"at" => 1, "input" => {kind: :choose, value: [1]}}], "finished_at" => 1},
  {"actions" => [{"at" => 1, "input" => {kind: :choose, value: "\xFF".force_encoding("UTF-8")}}], "finished_at" => 1}]
twice = input_trace(count: 2)
twice["actions"][1]["input"]["press_id"] = 1
invalid << twice
twice = input_trace(count: 2)
twice["actions"][1]["at"] = 99
invalid << twice
invalid.each do |trace|
  before = Marshal.dump(state)
  assert_raises(protocol::InvalidSubmission) { prepare_private(state, 0, trace) }
  assert_equal(before, Marshal.dump(state))
end

# No overall timer for Simon: only an explicit commit boundary closes it.
state = private_state(commit_deadline_ms: nil)
rejected_unchanged(state) { protocol.close_commits(state, now_ms: 1_000_000_000) }
rejected_unchanged(state) { protocol.expire_reveals(state, now_ms: 1_000_000_000) }
submission = prepare_private(state, 0, {"actions" => [], "finished_at" => 1_000_000_001})
assert(commit_private(state, submission, 0, now_ms: 1_000_001_010))
assert(protocol.forfeit(state, seat: 1, reason: :disconnected))
assert(protocol.close_commits(state, now_ms: 1_000_001_020))
assert(deliver_private(state, submission.reveal_plans.first, 0, now_ms: 1_000_001_030))
protocol.replay(state, adapter: capture)
assert_equal({1 => :disconnected}, capture.received[:forfeits])
assert_equal(1_000_000_001, capture.received[:traces][0]["finished_at"])

# Every missing reveal has its own timeout; absence does not fabricate trace.
state = private_state
[0, 1].each { |seat| assert(commit_private(state, prepare_private(state, seat, input_trace), seat)) }
assert(protocol.close_commits(state, now_ms: 2_000))
rejected_unchanged(state) { protocol.expire_reveals(state, now_ms: 6_999) }
assert(protocol.expire_reveals(state, now_ms: 7_000))
protocol.replay(state, adapter: capture)
assert_equal({}, capture.received[:traces])
assert_equal({0 => :reveal_timeout, 1 => :reveal_timeout}, capture.received[:forfeits])

# Damaged local payloads are unavailable, not recovered as valid responses.
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
state = private_state
submission = prepare_private(state, 0, input_trace, vault: vault)
assert(commit_private(state, submission, 0))
original = storage.read
[nil, {}, {"score" => 9_999}].each do |damaged|
  storage.update do |root|
    root.replace(Marshal.load(Marshal.dump(original)))
    root.fetch("entries").values.first["payload"] = damaged
  end
  assert_equal(nil, protocol.recover(state, seat: 0, user: "account-0", vault: vault))
  assert_equal({}, state[:reveals])
  assert_equal({}, state[:forfeits])
end

# Vault round/session/account isolation and restart recovery are exercised
# through the real file storage helper, not a pretend successfully saved flag.
Dir.mktmpdir("duck-private-") do |directory|
  state = private_state
  program = HiddenSubmissionFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(program.storage)
  first = prepare_private(state, 0, input_trace("rock"), vault: vault)
  assert(!program.writes.empty?, "Commit plan was returned before durable storage")
  assert(commit_private(state, first, 0))
  assert_equal(false, protocol.discard_local(state, seat: 0, user: "account-0", vault: vault))
  assert_raises(protocol::InvalidSubmission) { prepare_private(state, 0, input_trace("paper"), vault: vault) }
  fresh_vault = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(directory).storage)
  recovered = protocol.recover(state, seat: 0, user: "account-0", vault: fresh_vault)
  assert_equal(first.envelope.commitment, recovered.envelope.commitment, "Retry lost the accepted previous version")
  assert_equal(first.reveal_plans, recovered.reveal_plans)
  assert_equal(nil, protocol.recover(state, seat: 1, user: "account-0", vault: fresh_vault))
  assert_equal(nil, protocol.recover(state, seat: 0, user: "different-account", vault: fresh_vault))
  assert_equal(nil, protocol.recover(private_state(session_id: 92), seat: 0, user: "account-0", vault: fresh_vault))
  assert_equal(nil, protocol.recover(private_state(round_id: "other"), seat: 0, user: "account-0", vault: fresh_vault))
  assert(protocol.forfeit(state, seat: 1, reason: :disconnected))
  assert(protocol.close_commits(state, now_ms: 2_000))
  assert(deliver_private(state, recovered.reveal_plans.first, 0))
  assert(protocol.discard_local(state, seat: 0, user: "account-0", vault: fresh_vault))
  assert_equal(nil, protocol.recover(state, seat: 0, user: "account-0", vault: vault))

  program.blocked = [HiddenSubmissions::ProgramStorage::DEFAULT_PATH,
    HiddenSubmissions::ProgramStorage::DEFAULT_PATH + ".recovery.json"]
  fresh_state = private_state(round_id: "cannot-save")
  assert_raises(HiddenSubmissions::StorageError) { prepare_private(fresh_state, 0, input_trace, vault: vault) }
  assert_equal({}, fresh_state[:commitments])
  assert_equal(nil, protocol.recover(fresh_state, seat: 0, user: "account-0", vault: vault))
end

# Model verification can still fail after all pages arrive. Explicit technical
# cancellation prevents replay/settlement and is not converted to a loss.
assert(protocol.cancel(state, reason: "verification failed"))
assert_equal(:cancelled, state[:phase])
before = capture.calls
assert_raises(protocol::Cancelled) { protocol.replay(state, adapter: capture) }
assert_equal(before, capture.calls)
rejected_unchanged(state) { protocol.cancel(state, reason: "repeated") }

puts "PASS Duck Racing private round: durable commits, real-model replay, scope/privacy, malformed input, timeouts, recovery and cancellation"
