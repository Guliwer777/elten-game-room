require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/challenge_trace"
require_relative "../../../content/languages"
require_relative "../../support/duck_private_round"

include GameRoomTest::Assertions
include DuckPrivateRoundTest
engine = GameRoomDuckRacing::ChallengeEngine
trace_class = GameRoomDuckRacing::ChallengeTrace
verifier = GameRoomDuckRacing::TraceVerifier
turn_only = ENV["DUCK_NUMERIC_TURN_ONLY"] == "1"

registry = GameRoomContent::Registry.new
registry.register_language(GameRoomContent::LanguageProfile.new(id: "en", label: "English",
  alphabet: ("a".."z").to_a, normalizer: ->(text) { text.downcase }))
registry.register_pack(GameRoomContent::Pack.new(id: "test.duck.quiz", set_id: "test.duck.quiz", kind: "quiz", language_id: "en",
  version: 1, title: "Test", game_ids: ["quiz"], data: {"questions" => [
    {"id" => "q", "category" => "Test", "prompt" => "How many?", "correct" => "four", "wrong" => %w[one two three]}
  ]}))
resources = {
  questions: GameRoomDuckRacing::QuestionSets.prepare_selected(ids: ["test.duck.quiz"], language: "en", registry: registry)
}
make = lambda do |kind|
  {id: 9, kind: kind, participants: [0, 1], seed: 31, race_snapshot: {board_length: 30, laps: 3,
    racers: {0 => {progress: 3, feathers: 18, card_count: 3, die_sides: 12, die_rolls: 2},
      1 => {progress: 37, feathers: 18, card_count: 5, die_sides: 3, die_rolls: 2}}}}
end

# Each private type finishes, round-trips its actual accepted input and is
# settled using replayed rules. Correct answers here are test fixtures, not
# a production bot's observation.
private_types = GameRoomDuckRacing::Challenges::BY_ID.keys - engine::SHARED - engine::REALTIME
selected_types = turn_only ? ["rock_paper_scissors"] : private_types
if ENV['DUCK_SPEED_ONLY'] == '1'
  selected_types &= engine::SPEED_TYPES
end
selected_types.each do |kind|
  challenge = make.call(kind)
  traces = [0, 1].to_h do |seat|
    trace = trace_class.new(challenge, seat: seat, resources: resources)
    assert_raises(ArgumentError) { trace.snapshot }
    model = trace.state[:model]
    case kind
    when "rock_paper_scissors"
      assert(trace.submit({kind: :choose, value: seat.zero? ? "paper" : "rock", press_id: 1}, at: 900))
    when "guess_number", *GameRoomDuckRacing::NumericChallenges::ANSWER_TYPES
      assert(trace.submit({kind: :answer, value: model[:answer], press_id: 1}, at: 900 + seat * 2_000))
    when "count_ducks", "rhythm", "simon"
      audio = engine.stimulus(trace.state, seat: seat)
      end_at = audio[:events].map { |cue| cue[:offset_ms] + cue[:duration_ms] }.max
      assert(trace.submit({kind: :playback_finished, playback_id: audio[:id]}, at: end_at))
      if kind == "count_ducks"
        assert(trace.submit({kind: :answer, value: audio[:events].length, press_id: 1}, at: end_at + 900))
      elsif kind == "rhythm"
        assert(trace.submit({kind: :begin, press_id: 1}, at: end_at + 900))
        assert(trace.tick(at: end_at + 3_900))
      else
        wrong = audio[:events][0][:tone] % 5 + 1
        assert(trace.submit({kind: :tone, value: wrong, press_id: 1}, at: end_at + 900))
      end
    when "hit_duck"
      5.times do |index|
        audio = engine.stimulus(trace.state, seat: seat)
        assert(trace.submit({kind: :playback_started, playback_id: audio[:id]}, at: index * 4_000))
        assert(trace.submit({kind: :target, value: 5, press_id: index + 1}, at: index * 4_000 + 500))
      end
    when "quiz"
      assert(trace.submit({kind: :answer, value: model[:question][:correct_index], press_id: 1}, at: 900))
    else raise "Missing private trace test: #{kind}"
    end
    assert(trace.finished?, "#{kind}: own result did not finish")
    frozen = Marshal.dump(trace.state)
    assert_equal(false, trace.submit({kind: :answer, value: 1, press_id: 99}, at: 90_000))
    assert_equal(frozen, Marshal.dump(trace.state))
    view = engine.view(trace.state, seat: seat)
    assert_equal(false, view.key?(:correct_index))
    assert_equal(false, view.key?(:answer))
    assert_equal(false, view.key?(:results))
    [seat, trace.snapshot]
  end
  unless engine::FIRST_ANSWER.include?(kind)
    protocol = private_state(commit_deadline_ms: 2_000_000)
    prepared = traces.to_h { |seat, trace| [seat, prepare_private(protocol, seat, trace)] }
    prepared.each { |seat, value| assert(commit_private(protocol, value, seat)) }
    assert(PRIVATE_ROUND.close_commits(protocol, now_ms: 2_000))
    prepared.each do |seat, value|
      value.reveal_plans.reverse_each { |plan| assert(deliver_private(protocol, plan, seat)) }
      assert_equal(value.envelope.payload, protocol[:reveals][seat], "#{kind}: wire codec changed accepted input")
    end
  end
  verify = verifier.new(challenge: challenge, balances: {0 => 18, 1 => 18}, resources: resources)
  if engine::FIRST_ANSWER.include?(kind)
    traces.each { |seat, trace| assert_equal(true, verify.verify_attempt(seat, trace)[:correct]) }
    assert_raises(verifier::InvalidTrace) { verify.verify_attempt(8, traces[0]) }
    # Concurrent correct attempts are settled one at a time by Session's
    # accepted event order, never by comparing their local completion times.
    assert_raises(ArgumentError) { verify.replay(traces: traces, forfeits: []) }
    next
  end
  resolved = verify.replay(traces: traces, forfeits: [])
  assert_equal([0, 1], resolved.results.keys.sort)
  assert(resolved.settlement.balances.values.all? { |balance| balance >= 0 })
  assert_equal(resolved, verify.replay(traces: traces.to_a.reverse.to_h, forfeits: []))
  assert_raises(verifier::InvalidTrace) { verify.replay(traces: traces.merge(8 => traces[0]), forfeits: []) }
end
assert_equal(10, private_types.length)
GameRoomDuckRacing::NumericChallenges::TURN_TYPES.each do |kind|
  assert(engine::SEQUENTIAL.include?(kind))
  assert_equal(false, private_types.include?(kind))
  assert_raises(ArgumentError) { trace_class.new(make.call(kind), seat: 0) }
  assert_raises(ArgumentError) { verifier.new(challenge: make.call(kind), balances: {0 => 18, 1 => 18}) }
end

# Repeated physical keys, rewind, repeated action, unfinished/forged traces,
# late answers and injected scores cannot be accepted as final results.
c = make.call("rock_paper_scissors")
t = trace_class.new(c, seat: 0)
input = {kind: :choose, value: "rock", press_id: 1}
assert_equal(false, t.submit(input.merge(repeat: true), at: 500))
assert_equal(false, t.submit(input, at: 15_000))
assert(t.submit(input, at: 1_000))
v = verifier.new(challenge: c, balances: {0 => 18, 1 => 18})
good = t.snapshot
assert_equal({0 => 21, 1 => 15},
  v.replay(traces: {0 => good}, forfeits: [1]).settlement.balances)
[
  good.merge("score" => 0),
  good.merge("finished_at" => 1),
  good.merge("actions" => good["actions"] * 2),
  {"actions" => [], "finished_at" => 0},
  {"actions" => [{"at" => 15_000, "input" => input.transform_keys(&:to_s).merge("kind" => input[:kind].to_s)}], "finished_at" => 15_000}
].each do |bad|
  assert_raises(verifier::InvalidTrace) { v.replay(traces: {0 => bad}, forfeits: [1]) }
end
assert_raises(verifier::InvalidTrace) { v.replay(traces: {0 => good}, forfeits: [0, 1]) }

# An excluded participant cannot win blackjack because everybody else went
# bust. The settlement contract retains the verified players' bust penalties.
result = engine.settlement("blackjack", balances: {0 => 18, 1 => 18}, results: {0 => {score: 23}, 1 => {score: 0}}, excluded: [1])
assert_equal(nil, result.winner)
assert_equal({0 => 16, 1 => 18}, result.balances)
assert_equal(0, engine.settlement("rock_paper_scissors", balances: {0 => 18, 1 => 18},
  results: {0 => {choice: "rock"}, 1 => {choice: nil}}).winner)

# Global expiry must not expose the answer before the private round reveals.
unless turn_only
  s = engine.start(make.call("quiz"), resources: resources)
  engine.expire(s, now_ms: 20_000)
  assert_equal(false, engine.view(s, seat: 0).key?(:correct_index))
  assert(engine.view(s, seat: 0, revealed: true).key?(:correct_index))
  assert_raises(ArgumentError) { verifier.new(challenge: make.call("audio_ball"), balances: {0 => 18, 1 => 18}) }
end
puts "PASS Duck Racing challenge dispatch and private input trace verification#{turn_only ? ' (numeric turns and private RPS only)' : ''}"
