require_relative 'challenge_audio_helpers'
require_relative '../../../games/duck_racing_support/challenge_trace'
include DuckChallengeAudioTest

# BASS can report a stopped decoder while the device still drains buffered
# samples. The live rhythm failure reported 0.098833 s of a 0.1535 s tone at
# finished? == true, then reached the actual end on a later UI frame.
module NativeBufferedTail
  attr_accessor :status_lead_ms

  def position
    return super unless @started
    ratio = @frequency / 48_000
    [[(@program.now_ms - @started - 45) / 1000.0 * ratio, 0.0].max, length].min
  end

  def playing?
    super && @program.now_ms - @started < @duration_ms * 48_000 / @frequency - @status_lead_ms.to_i
  end
end

[[:simon, 1, 0], [:simon, 5, 7], [:rhythm, 'j', 0], [:pitch, 8, 12]].each do |sound, tone, semitones|
  program = Program.new
  program.duration_ms = 153.5
  program.next_sound = ->(sound) { sound.extend(NativeBufferedTail) }
  audio, _program, actions, errors = presenter(program)
  audio.play(pulse(sound: sound, tone: tone))
  at(audio, program, 0)
  duration = (program.duration_ms / (2.0**(semitones / 12.0))).ceil
  at(audio, program, duration + 2)
  assert_equal([], errors, 'A naturally draining device buffer was treated as an interrupted tone')
  assert(audio.busy?, 'Playback acknowledged before the device reached the end')
  assert_equal([:playback_started], actions.map { |action, _| action[:kind] })
  at(audio, program, duration + 50)
  assert_equal([], errors)
  assert(!audio.busy?)
  assert_equal([:playback_started, :playback_finished], actions.map { |action, _| action[:kind] })
  audio.close
end

# A decoder may also stop before the nominal duration. Waiting for its real
# position is safe; declaring a failure immediately is not.
program = Program.new
program.duration_ms = 153.5
program.next_sound = ->(sound) { sound.extend(NativeBufferedTail); sound.status_lead_ms = 30 }
audio, _program, actions, errors = presenter(program)
audio.play(pulse(sound: :rhythm, tone: 'f'))
at(audio, program, 0)
at(audio, program, 129)
assert_equal([], errors)
assert(audio.busy?)
at(audio, program, 205)
assert_equal([], errors)
assert_equal(2, actions.length)
audio.close

# Genuine stopping is still an error, not a successful or indefinitely hung
# sequence. Do not acknowledge another cue while the first remains incomplete.
program = Program.new
audio, _program, actions, errors = presenter(program)
sequence = pulse(sound: :rhythm, tone: 'j')
sequence[:events] << sequence[:events].first.merge(offset_ms: 250, tone: 'f')
audio.play(sequence)
at(audio, program, 0)
program.sounds.first.early_stop = true
at(audio, program, 110)
assert_equal([], errors)
assert_equal(1, program.events.length)
assert_equal(1, actions.length)
at(audio, program, 2_151)
assert_equal([:playback_interrupted], errors.map(&:code))
assert_equal(1, program.events.length)
assert_equal(1, actions.length)
assert(!audio.busy?)
assert_equal([], program.managed)

# The final acknowledgment carries actual starts even when the device tail
# delays the next very closely spaced cue. Scoring therefore sees that delay.
program = Program.new
program.duration_ms = 153.5
program.next_sound = ->(sound) { sound.extend(NativeBufferedTail) }
audio, _program, actions, errors = presenter(program)
sequence = pulse(sound: :rhythm, tone: 'j')
sequence[:events] << sequence[:events].first.merge(offset_ms: 110, tone: 'f')
audio.play(sequence)
at(audio, program, 0)
at(audio, program, 110)
assert_equal(1, program.events.length)
at(audio, program, 205)
assert_equal([0, 205], program.events.map { |event| event[:at] })
at(audio, program, 365)
assert_equal(1, actions.length)
at(audio, program, 415)
assert_equal([], errors)
assert_equal([0, 205], actions.last.first[:onsets_ms])
assert_equal(415, actions.last.last)
audio.close

# A full private attempt includes playback acknowledgments only after every
# native-like tail. Both participants can reproduce their own audible timing
# and the verifier computes equal results from their accepted input traces.
challenge = {id: 1, kind: 'rhythm', participants: [0, 1],
  seed: 269_515_291_007_661_432_382_244_678_656_742_254_800}
engine = GameRoomDuckRacing::ChallengeEngine
traces = {}
challenge[:participants].each do |seat|
  trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat)
  program = Program.new
  program.duration_ms = 153.5
  program.next_sound = ->(sound) { sound.extend(NativeBufferedTail) }
  audio, _program, actions, errors = presenter(program) do |action, time|
    accepted = trace.submit(action, at: time)
    assert_equal(action[:kind] == :playback_finished, accepted)
  end
  stimulus = engine.stimulus(trace.state, seat: seat)
  audio.play(stimulus)
  at(audio, program, 0)
  drain(audio, program, step: seat.zero? ? 7 : 43)
  assert_equal([], errors)
  onsets = actions.last.first.fetch(:onsets_ms)
  start = program.now_ms + 400 + seat * 300
  assert(trace.submit({kind: :begin, press_id: 1}, at: start))
  stimulus[:events].each_with_index do |event, index|
    assert(trace.submit({kind: :tone, value: event[:tone], press_id: index + 2},
      at: start + 200 + onsets[index] - onsets.first))
  end
  assert(trace.finished?)
  assert_equal(Rational(100), engine.result_for(trace.state, seat)[:score])
  traces[seat] = trace.snapshot
  audio.close
end
verified = GameRoomDuckRacing::TraceVerifier.new(challenge: challenge, balances: {0 => 18, 1 => 18}).replay(traces: traces, forfeits: [])
assert_equal({0 => {score: Rational(100)}, 1 => {score: Rational(100)}}, verified.results)
assert_equal({0 => 18, 1 => 18}, verified.settlement.balances)

report('Duck challenge native buffered audio tails and genuine interruption')
