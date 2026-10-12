require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

# Read the real Opus duration (last granule minus pre-skip) without requiring
# an audio device or an additional command-line decoder in the test runner.
path = File.expand_path('../../../Audio/duck_quack.opus', __dir__)
bytes = File.binread(path)
header = bytes.index('OpusHead')
assert(header, 'The quack is not an Opus stream')
assert_equal(1, bytes.getbyte(header + 9))
assert_equal(48_000, bytes.byteslice(header + 12, 4).unpack1('V'))
pre_skip = bytes.byteslice(header + 10, 2).unpack1('v')
offset, granule = 0, nil
while offset < bytes.bytesize
  assert_equal('OggS', bytes.byteslice(offset, 4))
  granule = bytes.byteslice(offset + 6, 8).unpack1('Q<')
  count = bytes.getbyte(offset + 26)
  offset += 27 + count + bytes.byteslice(offset + 27, count).bytes.sum
end
duration = Rational(granule - pre_skip, 48_000)
assert(duration.between?(0.380, 0.390), 'The full short quack was changed or truncated')
assert(bytes.include?('https://freesound.org/people/Breviceps/sounds/445960/'))
assert(bytes.include?('CC0 1.0'))

# The musical source is the approved stereo marimba C4, not a Pong sound.
assert_equal('duck_note_c', PLAYER::TONE_ASSET)
note_path = File.expand_path("../../../Audio/#{PLAYER::TONE_ASSET}.opus", __dir__)
note_bytes = File.binread(note_path)
note_header = note_bytes.index('OpusHead')
assert(note_header, 'The musical source is not Opus')
assert_equal(2, note_bytes.getbyte(note_header + 9))
assert_equal(48_000, note_bytes.byteslice(note_header + 12, 4).unpack1('V'))
note_skip = note_bytes.byteslice(note_header + 10, 2).unpack1('v')
note_offset, note_granule = 0, nil
while note_offset < note_bytes.bytesize
  assert_equal('OggS', note_bytes.byteslice(note_offset, 4))
  note_granule = note_bytes.byteslice(note_offset + 6, 8).unpack1('Q<')
  segments = note_bytes.getbyte(note_offset + 26)
  note_offset += 27 + segments + note_bytes.byteslice(note_offset + 27, segments).bytes.sum
end
assert_equal(Rational(150, 1000), Rational(note_granule - note_skip, 48_000))
assert(note_bytes.include?('https://freesound.org/people/joesh2/sounds/577691/'))
assert(note_bytes.include?('CC0 1.0'))

audio, program, actions, errors = presenter
program.durations[PLAYER::QUACK_ASSET] = (duration * 1000).ceil
program.durations[PLAYER::TONE_ASSET] = 150
program.gains.merge!(PLAYER::QUACK_ASSET => 0.41, PLAYER::TONE_ASSET => 0.23)
quack_duration = program.durations.fetch(PLAYER::QUACK_ASSET)
audio.play(pulse)
at(audio, program, 0)
assert_equal(PLAYER::QUACK_ASSET, program.events.last[:asset])
assert_equal(0.41, program.events.last[:volume])
at(audio, program, 150)
assert_equal(1, actions.length, 'A quack ended at the old tone duration')
at(audio, program, quack_duration - 1)
assert_equal(1, actions.length)
at(audio, program, quack_duration)
assert_equal([{kind: :playback_finished, playback_id: 1}, quack_duration], actions.last)

audio.play(pulse(id: 2, sound: :pitch, tone: 1))
at(audio, program, program.now_ms)
assert_equal(PLAYER::TONE_ASSET, program.events.last[:asset])
assert_equal(0.23, program.events.last[:volume])
program.gains[PLAYER::TONE_ASSET] = 0.19
program.gains[PLAYER::QUACK_ASSET] = 0.60
at(audio, program, program.now_ms + 20)
assert_equal(0.19, program.sounds.last.volume)
drain(audio, program)
audio.play(pulse(id: 3, sound: :target, pan: -1))
at(audio, program, program.now_ms)
assert_equal(PLAYER::QUACK_ASSET, program.events.last[:asset])
assert_equal(-1.0, program.events.last[:pan])
assert_equal(0.60, program.events.last[:volume])
assert_equal([PLAYER::QUACK_ASSET, PLAYER::TONE_ASSET], program.requested_assets)
drain(audio, program)

# The same sequence role switches back to its existing tone stream. The
# feedback role has its own handle and cannot truncate that sequence.
audio.play(pulse(id: 4, sound: :pitch, tone: 8))
at(audio, program, program.now_ms)
assert_equal(2, program.sounds.length)
assert_equal(96_000, program.events.last[:frequency])
drain(audio, program)
audio.sound_event(id: 1, sound: :memory, tone: 1)
at(audio, program, program.now_ms)
assert_equal(3, program.sounds.length)
assert_equal(PLAYER::MEMORY_ASSETS.first, program.events.last[:asset])
drain(audio, program)
program.enabled_assets[PLAYER::QUACK_ASSET] = false
audio.play(pulse(id: 5))
at(audio, program, program.now_ms)
assert_equal(0.0, program.events.last[:volume])
drain(audio, program)
assert_equal(:playback_finished, actions.last.first[:kind])
assert_equal([], errors)
audio.close
assert_equal([1, 1, 1], program.sounds.map(&:closes))
assert_equal([], program.managed)

report('Duck quack asset, full duration, per-asset volume and role/asset stream cache')
