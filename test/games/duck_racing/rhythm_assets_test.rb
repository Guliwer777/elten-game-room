require 'json'
require 'digest'
require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

expected = {'f' => 'duck_rhythm_f', 'j' => 'duck_rhythm_j'}
durations = {'duck_rhythm_f' => 337, 'duck_rhythm_j' => 167}
audio, program, actions, errors = presenter
program.durations.merge!(durations)

# Practice, the demonstrated rhythm and accepted key presses use the same
# two recordings at their original pitch. Repeated use reuses each handle.
expected.each do |key, asset|
  assert(audio.preview(sound: :rhythm, tone: key))
  at(audio, program, program.now_ms)
  assert_equal(asset, program.events.last[:asset])
  assert_equal(48_000, program.events.last[:frequency])
  assert_equal(0.0, program.events.last[:pan])
  drain(audio, program)
end
2.times do |round|
  stimulus = {id: round + 3, requested_ms: program.now_ms, events: %w[f j f j].each_with_index.map do |key, index|
    {sound: :rhythm, tone: key, offset_ms: index * 200, duration_ms: 150}
  end}
  assert(audio.play(stimulus))
  assert_equal(false, audio.play(stimulus))
  first_event = program.events.length
  drain(audio, program)
  heard = program.events.drop(first_event)
  assert_equal(expected.values * 2, heard.map { |event| event[:asset] })
  assert_equal(heard.map { |event| event[:at] }, actions.last.first[:onsets_ms])
  heard.each_cons(2) do |left, right|
    assert(right[:at] >= left[:at] + durations.fetch(left[:asset]), 'A snare was truncated')
  end
  expected.each do |key, asset|
    assert(audio.feedback(sound: :rhythm, tone: key))
    assert_equal(asset, program.events.last[:asset])
    assert_equal(48_000, program.events.last[:frequency])
    drain(audio, program)
  end
end
assert_equal(4, program.sounds.length, 'One reusable handle per role and recording')
assert_equal([], errors)
audio.close
assert_equal([1] * 4, program.sounds.map(&:closes))
assert_equal([], program.managed)
assert_equal(expected, PLAYER::RHYTHM_ASSETS)

# Validate both delivered Opus assets and the native/source manifests.
root = File.expand_path('../../..', __dir__)
app = File.binread(File.join(root, '__app.rb'))
embedded = JSON.parse(app.split("=begin Elten3AppInfo\n", 2).last.split('=end Elten3AppInfo', 2).first)
manifest = JSON.parse(File.read(File.join(root, 'manifest.json')))
hashes = expected.values.map do |asset|
  bytes = File.binread(File.join(root, 'Audio', asset + '.opus'))
  header = bytes.index('OpusHead')
  assert(header)
  assert_equal(2, bytes.getbyte(header + 9))
  assert_equal(48_000, bytes.byteslice(header + 12, 4).unpack1('V'))
  pre_skip = bytes.byteslice(header + 10, 2).unpack1('v')
  offset, granule = 0, nil
  while offset < bytes.bytesize
    assert_equal('OggS', bytes.byteslice(offset, 4))
    granule = bytes.byteslice(offset + 6, 8).unpack1('Q<')
    segments = bytes.getbyte(offset + 26)
    offset += 27 + segments + bytes.byteslice(offset + 27, segments).bytes.sum
  end
  assert(((granule - pre_skip) / 48.0 - durations.fetch(asset)).abs < 1.0)
  [manifest, embedded].each { |source| assert(source.fetch('required_assets').fetch('sounds').include?(asset)) }
  Digest::SHA256.hexdigest(bytes)
end
assert_equal(2, hashes.uniq.length)
assert(!app.include?("\r\n"), 'Keep the native manifest LF-only')

# Both new sounds remain subject to game volume and the shared background gate.
Program.settings = {'background_game_sounds' => 'all'}
audio, program, actions, errors = presenter
covered = true
gate = GameRoomSoundOutput.new(program, audio_game: true, covered: -> { covered })
expected.each do |key, asset|
  program.gains[asset] = 0.4
  assert(audio.feedback(sound: :rhythm, tone: key))
  assert_equal(0.0, program.events.last[:volume])
  drain(audio, program)
end
covered = false
expected.each do |key, asset|
  assert(audio.feedback(sound: :rhythm, tone: key))
  assert_equal(0.4, program.events.last[:volume])
  drain(audio, program)
end
audio.close
gate.tick
assert_equal({}, gate.instance_variable_get(:@voices))
assert_equal([], errors)
gate.close
Program.settings = nil

report('Rhythm F/J recordings: practice, stimulus, key echo, full tails, manifests, cleanup and muting')
