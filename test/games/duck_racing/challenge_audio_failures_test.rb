require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

[:missing, :start, :stalled, :paused, :broken, :closed, :early_stop, :format].each do |failure|
  program = Program.new
  program.missing = true if failure == :missing
  program.next_sound = ->(sound) { sound.fail_start = true } if failure == :start
  program.next_sound = ->(sound) { sound.frequency = 0 } if failure == :format
  audio, _program, actions, errors = presenter(program)
  audio.play(pulse)
  at(audio, program, 0)
  sound = program.sounds.first
  case failure
  when :stalled
    sound.stalled = true
    at(audio, program, 2_150)
  when :paused
    sound.pause
    at(audio, program, 40)
  when :broken
    sound.broken = true
    at(audio, program, 40)
  when :closed
    sound.close
    at(audio, program, 40)
  when :early_stop
    sound.early_stop = true
    at(audio, program, 170)
    assert_equal([], errors, 'An incomplete tail must first be allowed to drain')
    at(audio, program, 2_150)
  end
  assert_equal(1, errors.length, "#{failure}: audio failure was not reported exactly once")
  assert(errors.first.is_a?(PLAYER::PlaybackError))
  assert(!actions.any? { |action, _| action[:kind] == :playback_finished }, "#{failure}: failure looked like completed playback")
  assert(!audio.busy?)
  assert_equal(false, audio.play(pulse(id: 2)))
  assert_equal(false, at(audio, program, 9_000))
  assert_equal([], program.managed)
  audio.close
  assert_equal(1, errors.length)
end

# The emergency limit examines finished? first: an ordinary late frame after
# a sound completed is not an audio failure and does not compress the rest.
audio, program, actions, errors = presenter
source = pulse
source[:events] << source[:events].first.merge(offset_ms: 500)
source[:events] << source[:events].first.merge(offset_ms: 1_000)
audio.play(source)
at(audio, program, 0)
at(audio, program, 9_000)
assert_equal([0, 9_000], program.events.map { |entry| entry[:at] })
assert_equal(1, actions.length)
at(audio, program, 9_150)
assert_equal(2, program.events.length)
at(audio, program, 9_500)
assert_equal([0, 9_000, 9_500], program.events.map { |entry| entry[:at] })
at(audio, program, 9_650)
assert_equal(2, actions.length)
assert_equal([], errors)
audio.close

# Background muting and user zero volume leave the device's stream running:
# the last sound still acknowledges and the model's response timer starts.
[:background, :disabled, :zero].each do |mode|
  program = Program.new
  program.enabled = false if mode == :disabled
  program.gain = 0.0 if mode == :zero
  Program.settings = {'background_game_sounds' => mode == :background ? 'all' : 'never'}
  covered = mode == :background
  gate = GameRoomSoundOutput.new(program, audio_game: true, covered: -> { covered })
  state = MODEL.start('simon', seats: [0, 1], seed: 79, now_ms: 0)
  audio, _program, actions, errors = presenter(program) do |action, time|
    MODEL.submit(state, seat: 0, action: action, now_ms: time)
  end
  audio.play(MODEL.stimulus(state, seat: 0))
  at(audio, program, 0)
  assert_equal(0.0, program.events.first[:volume])
  drain(audio, program)
  assert(program.events.all? { |event| event[:volume].zero? })
  assert_equal(actions.last.last + 5_000, MODEL.view(state, seat: 0)[:own][:deadline_ms])
  assert_equal([], errors)
  audio.close
  gate.tick
  assert_equal({}, gate.instance_variable_get(:@voices))
  gate.close
end

# Dynamic gain is applied to existing playback. A suppressed one-shot must
# not suddenly become audible on return, while its new use may be audible.
Program.settings = {'background_game_sounds' => 'all'}
audio, program, actions, errors = presenter
covered = false
gate = GameRoomSoundOutput.new(program, audio_game: true, covered: -> { covered })
audio.play(pulse)
at(audio, program, 0)
assert_equal(0.65, program.sounds.first.volume)
program.gain = 0.25
at(audio, program, 20)
assert_equal(0.25, program.sounds.first.volume)
covered = true
at(audio, program, 40)
assert_equal(0.0, program.sounds.first.volume)
covered = false
at(audio, program, 60)
assert_equal(0.0, program.sounds.first.volume)
at(audio, program, 150)
audio.play(pulse(id: 2))
at(audio, program, 160)
assert_equal(0.25, program.sounds.first.volume)
drain(audio, program)
assert_equal([], errors)
audio.close
gate.close

# Queue overflow is an explicit incomplete-presentation error, never loss of
# the earliest reveal, unnoticed overwriting or an unbounded handle backlog.
audio, program, actions, errors = presenter
(1..PLAYER::FEEDBACK_LIMIT).each do |id|
  assert(audio.sound_event(id: id, sound: :memory, tone: 1))
end
assert_equal(false, audio.sound_event(id: 33, sound: :memory, tone: 1))
assert_equal(:queue_overflow, errors.first.code)
assert_equal([], actions)
assert_equal([], program.sounds)
assert(!audio.busy?)

report('Duck challenge audio failures, silence, dynamic volume and delayed UI')
