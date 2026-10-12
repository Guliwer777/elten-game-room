require 'json'
require 'digest'
require_relative 'challenge_audio_helpers'
include DuckChallengeAudioTest

# Use the delivered recordings' real lengths, not the old 150 ms sine-wave
# fixture. The presenter must let each reveal finish before starting another.
sources = [
  ['duck_memory_bark', 'kwahmah_02', '277058', 2, 0.389],
  ['duck_memory_bell', 'NoisyRedFox', '759839', 1, 0.601],
  ['duck_memory_drop', 'paespedro', '174718', 2, 0.472],
  ['duck_memory_clap', 'Sorinious_Genious', '561089', 2, 0.396],
  ['duck_memory_zip', 'ref57', '361382', 2, 0.650]
]
assert_equal(sources.map(&:first), PLAYER::MEMORY_ASSETS)
root = File.expand_path('../../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'manifest.json')))
app = File.read(File.join(root, '__app.rb'))
embedded = JSON.parse(app.split("=begin Elten3AppInfo\n", 2).last.split("=end Elten3AppInfo", 2).first)
audio, program, actions, errors = presenter
hashes = []
sources.each_with_index do |(asset, author, id, channels, duration), index|
  bytes = File.binread(File.join(root, 'Audio', asset + '.opus'))
  hashes << Digest::SHA256.hexdigest(bytes)
  header = bytes.index('OpusHead')
  assert(header)
  assert_equal(channels, bytes.getbyte(header + 9))
  assert_equal(48_000, bytes.byteslice(header + 12, 4).unpack1('V'))
  assert(bytes.include?("https://freesound.org/people/#{author}/sounds/#{id}/"))
  assert(bytes.include?('CC0 1.0'))
  pre_skip = bytes.byteslice(header + 10, 2).unpack1('v')
  offset, granule = 0, nil
  while offset < bytes.bytesize
    assert_equal('OggS', bytes.byteslice(offset, 4))
    granule = bytes.byteslice(offset + 6, 8).unpack1('Q<')
    segments = bytes.getbyte(offset + 26)
    offset += 27 + segments + bytes.byteslice(offset + 27, segments).bytes.sum
  end
  actual = (granule - pre_skip) / 48_000.0
  assert((actual - duration).abs < 0.002)
  assert(actual.between?(0.25, 1.0), 'Memory sounds must stay short')
  program.durations[asset] = (actual * 1000).ceil
  program.gains[asset] = 0.2 + index * 0.1
  [manifest, embedded].each { |source| assert(source.fetch('required_assets').fetch('sounds').include?(asset)) }
end
assert_equal(5, hashes.uniq.length, 'Memory needs five genuinely different recordings')
assert(!app.include?("\r\n"), 'Keep the native manifest LF-only')

# Two complete rounds keep the same mapping and five reusable handles;
# repeated snapshots do not play the same reveal twice.
2.times do |round|
  sources.each_with_index do |(asset, *_), index|
    id = round * 5 + index + 1
    event = {id: id, sound: :memory, tone: index + 1, seat: round, position: index}
    assert(audio.sound_event(event))
    assert_equal(false, audio.sound_event(event))
  end
  drain(audio, program)
end
assert_equal(sources.map(&:first) * 2, program.events.map { |event| event[:asset] })
assert_equal([48_000] * 10, program.events.map { |event| event[:frequency] })
assert_equal([0.0] * 10, program.events.map { |event| event[:pan] })
program.events.each_cons(2) do |previous, following|
  assert(following[:at] >= previous[:at] + program.durations.fetch(previous[:asset]), 'A reveal was cut off')
end
program.events.each { |event| assert_equal(program.gains.fetch(event[:asset]), event[:volume]) }
assert_equal(5, program.sounds.length)
assert_equal([], errors)
assert_equal([], actions)
audio.close
assert_equal([1] * 5, program.sounds.map(&:closes))
assert_equal([], program.managed)

# Each memory asset observes the same muting gate, without affecting the
# reveal queue's completion or leaking a sound on returning to the window.
Program.settings = {'background_game_sounds' => 'all'}
audio, program, actions, errors = presenter
covered = true
gate = GameRoomSoundOutput.new(program, audio_game: true, covered: -> { covered })
sources.each_index { |i| audio.sound_event(id: i + 1, sound: :memory, tone: i + 1) }
drain(audio, program)
assert_equal([0.0] * 5, program.events.map { |event| event[:volume] })
assert_equal([], errors)
audio.close
gate.tick
assert_equal({}, gate.instance_variable_get(:@voices))
gate.close
Program.settings = nil

report('Five short Memory assets: licenses, manifests, full sequential playback, deduplication, handles and muting')
