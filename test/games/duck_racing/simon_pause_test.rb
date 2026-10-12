require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

# Exercise the model and actual playback scheduler together. The initial
# sequence has no added delay; subsequent ones start one second after input.
state = MODEL.start('simon', seats: [0, 1], seed: 79, now_ms: 0)
audio, program, actions, errors = presenter do |action, time|
  MODEL.submit(state, seat: 0, action: action, now_ms: time)
end
press_id = 0
source = MODEL.stimulus(state, seat: 0)
assert_equal(0, source[:requested_ms])
assert_equal(1, source[:events].length, 'Simon must start with one sound')
audio.play(source)
at(audio, program, 0)
assert_equal(0, program.events.first[:at])
drain(audio, program)

32.times do |round|
  source[:events].each do |event|
    program.now_ms += 100
    press_id += 1
    assert(MODEL.submit(state, seat: 0,
      action: {kind: :tone, value: event[:tone], press_id: press_id}, now_ms: program.now_ms))
    assert(audio.feedback(sound: :simon, tone: event[:tone]))
  end
  completed_at = program.now_ms
  source = MODEL.stimulus(state, seat: 0)
  assert_equal(round + 2, source[:events].length)
  interval = [500 - (round + 1) * 10, 300].max
  assert_equal(Array.new(round + 1, interval),
    source[:events].each_cons(2).map { |first, second| second[:offset_ms] - first[:offset_ms] })
  assert_equal(completed_at + 1_000, source[:requested_ms])
  assert_equal(:listening, MODEL.view(state, seat: 0)[:own][:phase])
  assert_equal(nil, MODEL.view(state, seat: 0)[:own][:deadline_ms])
  assert_equal(false, MODEL.expire(state, now_ms: completed_at + 999))
  assert_equal(false, MODEL.submit(state, seat: 0,
    action: {kind: :tone, value: 1, press_id: press_id + 1}, now_ms: completed_at + 999))
  copy = Marshal.load(Marshal.dump(state))
  assert_equal(source, MODEL.stimulus(copy, seat: 0))
  assert(audio.play(source))
  event_count = program.events.length
  [1, 200, 999].each do |delta|
    at(audio, program, completed_at + delta)
    assert_equal(event_count, program.events.length, 'Next sequence started during the pause')
  end
  at(audio, program, completed_at + 1_000)
  assert_equal(event_count + 1, program.events.length)
  assert_equal(completed_at + 1_000, program.events.last[:at])
  assert_equal(false, audio.play(source), 'Refresh restarted the pause or sequence')
  drain(audio, program)
  onsets = program.events.drop(event_count).map { |event| event[:at] }
  assert_equal(source[:events].length, onsets.length, 'Playback skipped or repeated a sound')
  assert_equal(Array.new(round + 1, interval), onsets.each_cons(2).map { |first, second| second - first },
    'The presenter did not play the accelerating tempo')
  assert_equal(program.now_ms + 5_000, MODEL.view(state, seat: 0)[:own][:deadline_ms])
end

# The opponent's initial attempt is independent.
assert_equal(0, MODEL.stimulus(state, seat: 1)[:requested_ms])
wrong = source[:events].first[:tone] % 5 + 1
assert(MODEL.submit(state, seat: 0,
  action: {kind: :tone, value: wrong, press_id: press_id + 1}, now_ms: program.now_ms + 1))
assert_equal(32, state[:scores][0])
assert_equal(nil, MODEL.stimulus(state, seat: 0))
assert_equal(false, state[:finished])
assert_equal([], errors)
audio.close
report('Simon one-sound start, gradual tempo to 300ms, one-second pause, input gates, replay and score')
