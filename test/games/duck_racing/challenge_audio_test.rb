require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

# Acknowledgements follow the real sound handle, not the descriptor duration.
[90, 350, 900].each do |duration|
  program = Program.new
  program.duration_ms = duration
  audio, _program, actions, errors = presenter(program)
  source = pulse(duration_ms: 200)
  assert(audio.play(source))
  source[:events].clear
  assert_equal([], program.events)
  at(audio, program, 0)
  assert_equal([[{kind: :playback_started, playback_id: 1}, 0]], actions)
  at(audio, program, duration - 1)
  assert_equal(1, actions.length)
  at(audio, program, duration)
  assert_equal([{kind: :playback_finished, playback_id: 1}, duration], actions.last)
  assert_equal(false, audio.play(pulse))
  assert_equal(1, program.events.length)
  assert_equal([], errors)
  audio.close
  audio.close
  assert_equal([1], program.sounds.map(&:closes))
  assert_equal([], program.managed)
end

# Every model stimulus is playable. Target deadlines start at actual onset,
# whereas count/Simon deadlines begin only once all sounds have finished.
[22, 24, 25, 26, 28].each do |type|
  state = MODEL.start(type, seats: [0, 1], seed: 923, now_ms: 0)
  if type == 25
    assert(MODEL.submit(state, seat: 0, action: {kind: :preview, value: 3, press_id: 1}, now_ms: 0))
  end
  audio, program, actions, errors = presenter do |action, time|
    MODEL.submit(state, seat: 0, action: action, now_ms: time)
  end
  stimulus = MODEL.stimulus(state, seat: 0)
  expected_events = stimulus[:events].length
  assert(audio.play(stimulus))
  at(audio, program, 730)
  own = MODEL.view(state, seat: 0)[:own]
  assert_equal(type == 28 ? 3730 : (type == 25 ? 45_000 : nil), own[:deadline_ms])
  assert_equal(730, actions.first.last)
  drain(audio, program)
  assert_equal(expected_events, program.events.length)
  assert_equal(2, actions.length)
  assert_equal(:playback_finished, actions.last.first[:kind])
  assert_equal([], errors)
  assert_equal(nil, MODEL.stimulus(state, seat: 0))
  if type == 24
    assert_equal(program.events.map { |event| event[:at] }, actions.last.first[:onsets_ms])
  else
    assert(!actions.last.first.key?(:onsets_ms))
  end
  audio.close
end

# Ascending frequencies and all nine exact stereo positions; no source asset
# is altered; the same role retains separate handles for tones and quacks.
audio, program, actions, errors = presenter
frequencies = []
(1..8).each do |tone|
  audio.play(pulse(id: tone, sound: :pitch, tone: tone))
  at(audio, program, program.now_ms)
  frequencies << program.events.last[:frequency]
  drain(audio, program)
end
assert(frequencies.each_cons(2).all? { |left, right| left < right })
assert_equal(48_000, frequencies.first)
assert_equal(96_000, frequencies.last)
(1..9).each do |position|
  audio.play(pulse(id: position + 8, sound: :target, pan: Rational(position - 5, 4)))
  at(audio, program, program.now_ms)
  assert_equal((position - 5) / 4.0, program.events.last[:pan])
  drain(audio, program)
end
assert_equal(2, program.sounds.length)
assert_equal([PLAYER::TONE_ASSET, PLAYER::QUACK_ASSET], program.requested_assets)
assert_equal([], errors)
audio.close

# Two reveals received in the same frame remain separate, ordered sounds;
# a duplicate snapshot does not replay the reveal. Feedback uses a different
# channel and cannot restart or truncate an important scheduled sequence.
audio, program, actions, errors = presenter
first = {id: 1, sound: :memory, tone: 1, position: 7, seat: 0}
second = {id: 2, sound: :memory, tone: 5, position: 0, seat: 0}
assert(audio.sound_event(first))
assert(audio.sound_event(second))
assert_equal(false, audio.sound_event(first))
assert_equal(false, audio.sound_event(second))
at(audio, program, 0)
assert_equal(1, program.events.length)
at(audio, program, 149)
assert_equal(1, program.events.length)
at(audio, program, 150)
assert_equal([48_000, 48_000], program.events.map { |event| event[:frequency] })
assert_equal(PLAYER::MEMORY_ASSETS.values_at(0, 4), program.events.map { |event| event[:asset] })
drain(audio, program)
assert_equal([], actions)
assert(audio.feedback(sound: :simon, tone: 3))
drain(audio, program)
assert(audio.play(pulse(requested_ms: program.now_ms)))
assert_equal(false, audio.feedback(sound: :rhythm, tone: 'j'))
drain(audio, program)
assert_equal(4, program.sounds.length)
assert_equal([], errors)
audio.close
assert_equal([1, 1, 1, 1], program.sounds.map(&:closes))

# Simon uses C, D, E, F, G, including input feedback; sorting uses a full
# major scale. Memory uses five distinct, untransposed everyday sounds.
expected_ratios = [0, 2, 4, 5, 7].map { |semitones| 2.0**(semitones / 12.0) }
audio, program, actions, errors = presenter
(1..5).each do |tone|
  audio.play(pulse(id: tone, sound: :simon, tone: tone, requested_ms: program.now_ms))
  at(audio, program, program.now_ms)
  assert_equal(48_000 * expected_ratios[tone - 1], program.events.last[:frequency])
  drain(audio, program)
  assert(audio.feedback(sound: :simon, tone: tone))
  assert_equal(48_000 * expected_ratios[tone - 1], program.events.last[:frequency])
  drain(audio, program)
  audio.sound_event(id: tone, sound: :memory, tone: tone, position: tone, seat: 0)
  at(audio, program, program.now_ms)
  assert_equal(48_000, program.events.last[:frequency])
  assert_equal(PLAYER::MEMORY_ASSETS.fetch(tone - 1), program.events.last[:asset])
  drain(audio, program)
end
assert_equal([], errors)
audio.close

# Cancelling a stale preview produces no finish acknowledgement; replacing it
# takes the new ID and does not resurrect older sounds on another snapshot.
audio, program, actions, errors = presenter
audio.play(pulse)
at(audio, program, 0)
assert(audio.play(pulse(id: 2, sound: :pitch, tone: 8)))
at(audio, program, 10)
drain(audio, program)
assert_equal([:playback_started, :playback_started, :playback_finished], actions.map { |action, _| action[:kind] })
assert_equal([1, 2, 2], actions.map { |action, _| action[:playback_id] })
assert(audio.play(pulse(id: 3)))
at(audio, program, program.now_ms)
assert(audio.play(nil))
assert_equal(false, audio.play(nil))
assert_equal(false, audio.play(pulse(id: 2)))
assert(!audio.busy?)
audio.close
assert_equal([], errors)

# Callback re-entry cannot recursively advance the stream or clear the guard.
program = Program.new
calls = []
audio = PLAYER.new(program, clock_ms: -> { program.now_ms }, on_error: ->(error) { raise error },
  on_action: ->(action, _time) { calls << action; assert_equal(false, audio.step(program.now_ms)) })
audio.play(pulse)
at(audio, program, 0)
at(audio, program, 150)
assert_equal(2, calls.length)
audio.close

# A long Simon sequence remains actual playback, not a five-second timeout
# or a 30-sound fallback. Very fast accepted-key echo has no queue-length cap.
state = MODEL.start('simon', seats: [0, 1], seed: 79, now_ms: 0)
audio, program, actions, errors = presenter do |action, time|
  MODEL.submit(state, seat: 0, action: action, now_ms: time)
end
press_id = 0
(1..32).each do |level|
  source = MODEL.stimulus(state, seat: 0)
  assert_equal(level, source[:events].length)
  assert(audio.play(source))
  drain(audio, program)
  assert_equal(program.now_ms + 5_000, MODEL.view(state, seat: 0)[:own][:deadline_ms])
  source[:events].each do |event|
    program.now_ms += 1
    press_id += 1
    assert(MODEL.submit(state, seat: 0, action: {kind: :tone, value: event[:tone], press_id: press_id}, now_ms: program.now_ms))
    assert(audio.feedback(sound: :simon, tone: event[:tone]))
  end
end
assert_equal(32, MODEL.view(state, seat: 0)[:own][:completed_length])
assert_equal(33, MODEL.stimulus(state, seat: 0)[:events].length)
assert_equal(2, program.sounds.length)
assert_equal([], errors)
audio.close

# Invalid descriptors/keys do not start a sound or replace a valid sequence.
audio, program, actions, errors = presenter
audio.play(pulse)
invalid = [nil, 0, {}, pulse(id: -1), pulse(sound: :unknown), pulse(sound: :pitch, tone: 9),
  pulse(sound: :rhythm, tone: 'g'), pulse(sound: :simon, tone: 6), pulse(sound: :memory, tone: 0),
  pulse(sound: :memory, tone: 6), pulse(sound: :target, pan: Float::NAN),
  pulse(offset_ms: 1), pulse(duration_ms: 0)]
invalid.drop(1).each { |value| assert_raises(ArgumentError) { audio.play(value) } }
at(audio, program, 0)
assert_equal(1, actions.length)
assert_raises(ArgumentError) { at(audio, program, -1) }
program.now_ms = 150
audio.step
assert_equal(:playback_finished, actions.last.first[:kind])
audio.close

report('Duck challenge audio: all six adapters, real completion, inputs, stereo, bounded handles and cancellation')
