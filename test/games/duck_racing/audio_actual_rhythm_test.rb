require_relative 'challenge_audio_helpers'
require_relative '../../support/duck_private_round'
require_relative '../../../games/duck_racing_support/challenge_trace'
include DuckChallengeAudioTest

engine = GameRoomDuckRacing::ChallengeEngine
trace_class = GameRoomDuckRacing::ChallengeTrace
challenge = {id: 5, kind: 'rhythm', participants: [0, 1], seed: 31}
traces = {}

# The same nominal sequence plays with and without an actual inter-beat UI
# delay. Repeating the rhythm each participant really heard gives the same
# perfect result; the first input's reaction delay is deliberately different.
[false, true].each_with_index do |delayed, seat|
  trace = trace_class.new(challenge, seat: seat)
  model = trace.state[:model]
  stimulus = engine.stimulus(trace.state, seat: seat)
  tones = stimulus[:events].map { |cue| cue[:tone] }
  audio, program, actions, errors = presenter do |action, time|
    trace.submit(action, at: time)
  end
  program.durations.merge!('duck_rhythm_f' => 337, 'duck_rhythm_j' => 167)
  audio.play(stimulus)
  at(audio, program, 100)
  at(audio, program, 1_650) if delayed
  drain(audio, program)
  finish, completed_at = actions.last
  onsets = finish.fetch(:onsets_ms)
  assert_equal(program.events.map { |event| event[:at] }, onsets)
  assert_equal(tones.length, onsets.length)
  assert_equal([], errors)
  assert_equal(onsets, model[:private][:players][seat][:rhythm_onsets])
  start = completed_at + 900 + seat * 500
  assert(trace.submit({kind: :begin, press_id: 1}, at: start))
  tones.each_with_index do |tone, index|
    time = start + 500 + onsets[index] - onsets.first
    assert(trace.submit({kind: :tone, value: tone, press_id: index + 2}, at: time))
  end
  assert(trace.finished?)
  assert_equal(Rational(100), engine.result_for(trace.state, seat)[:score])
  traces[seat] = trace.snapshot
  onsets.clear
  assert_equal(tones.length, model[:private][:players][seat][:rhythm_onsets].length)
  audio.close
end

# Private commits/reveals carry only validated inputs and actual onset times,
# not a claimed score. The real verifier recomputes the same tied result.
helpers = Object.new.extend(DuckPrivateRoundTest)
protocol = GameRoomDuckRacing::PrivateRound
private_state = helpers.private_state
prepared = traces.to_h { |seat, trace| [seat, helpers.prepare_private(private_state, seat, trace)] }
prepared.each { |seat, submission| assert(helpers.commit_private(private_state, submission, seat, now_ms: 25_000)) }
assert(protocol.close_commits(private_state, now_ms: 25_000))
prepared.each do |seat, submission|
  while (plan = protocol.next_reveal_plan(private_state, submission))
    assert(helpers.deliver_private(private_state, plan, seat, now_ms: 25_001))
  end
end
capture = DuckPrivateRoundTest::CaptureReplay.new
protocol.replay(private_state, adapter: capture)
assert_equal(traces, capture.received[:traces])
verifier = GameRoomDuckRacing::TraceVerifier.new(challenge: challenge, balances: {0 => 10, 1 => 10})
result = verifier.replay(traces: capture.received[:traces], forfeits: capture.received[:forfeits].keys)
assert_equal({0 => {score: Rational(100)}, 1 => {score: Rational(100)}}, result.results)
assert_equal({0 => 10, 1 => 10}, result.settlement.balances)

# Invalid lists, ordering, domains or use in another action are rejected
# without mutating the model or advancing its input ID/time bookkeeping.
state = engine.start(challenge)
stimulus = engine.stimulus(state, seat: 0)
size = stimulus[:events].length
normal = stimulus[:events].map { |event| event[:offset_ms] }
now_ms = normal.last + 200
bad = [nil, {}, 'bad', [], normal[0...-1], normal + [now_ms], normal.map(&:to_f),
  [-1] + normal.drop(1), normal[0...-1] + [now_ms + 1], normal.reverse]
bad.each do |onsets|
  before = Marshal.dump(state)
  assert_equal(false, engine.submit(state, seat: 0,
    action: {kind: :playback_finished, playback_id: stimulus[:id], onsets_ms: onsets}, now_ms: now_ms))
  assert_equal(before, Marshal.dump(state))
end
before = Marshal.dump(state)
assert_equal(false, engine.submit(state, seat: 0,
  action: {kind: :playback_started, playback_id: stimulus[:id], onsets_ms: normal}, now_ms: now_ms))
assert_equal(before, Marshal.dump(state))
assert(engine.submit(state, seat: 0,
  action: {kind: :playback_finished, playback_id: stimulus[:id], onsets_ms: normal}, now_ms: now_ms))
normal.clear
assert_equal(size, state[:model][:private][:players][0][:rhythm_onsets].length)

# Replaying the rhythm replaces its actual reference. Omitting onsets is the
# compatible deterministic bot/model path and restores nominal intervals.
assert(engine.submit(state, seat: 0, action: {kind: :replay, press_id: 1}, now_ms: now_ms + 100))
second = engine.stimulus(state, seat: 0)
second_onsets = second[:events].map { |event| second[:requested_ms] + event[:offset_ms] }
invalid_before_request = second_onsets.map { |time| time - second[:requested_ms] }
assert_equal(false, engine.submit(state, seat: 0,
  action: {kind: :playback_finished, playback_id: second[:id], onsets_ms: invalid_before_request}, now_ms: second_onsets.last + 200))
assert(engine.submit(state, seat: 0, action: {kind: :playback_finished, playback_id: second[:id]}, now_ms: second_onsets.last + 200))
assert_equal(nil, state[:model][:private][:players][0][:rhythm_onsets])

['count_ducks', 'simon', 'dice_duel'].each do |kind|
  other = challenge.merge(kind: kind, race_snapshot: {racers: {
    0 => {die_sides: 6, die_rolls: 0}, 1 => {die_sides: 6, die_rolls: 0}}})
  state = engine.start(other)
  before = Marshal.dump(state)
  assert_equal(false, engine.submit(state, seat: 0,
    action: {kind: :playback_finished, playback_id: 1, onsets_ms: [0] * 6}, now_ms: 1_000))
  assert_equal(before, Marshal.dump(state))
end

# The envelope's structural validator also rejects arbitrary arrays outside
# this one acknowledgement field, before any reveal or model replay occurs.
[nil, [], [1] * 5, [1] * 11, [-1] * 6, ['1'] * 6, [1.0] * 6].each do |bad_onsets|
  malformed = {'actions' => [{'at' => 1_000, 'input' => {'kind' => 'playback_finished', 'playback_id' => 1, 'onsets_ms' => bad_onsets}}],
    'finished_at' => 1_000}
  assert_raises(protocol::InvalidSubmission) { helpers.prepare_private(helpers.private_state, 0, malformed) }
end
malformed = {'actions' => [{'at' => 1_000, 'input' => {'kind' => 'tone', 'press_id' => 1, 'onsets_ms' => [1] * 6}}], 'finished_at' => 1_000}
assert_raises(protocol::InvalidSubmission) { helpers.prepare_private(helpers.private_state, 0, malformed) }

report('Duck rhythm: actual audio intervals, input validation and complete private-round replay')
