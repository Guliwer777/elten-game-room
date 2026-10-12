# frozen_string_literal: true

require 'json'
require 'open3'
require 'digest'
require_relative '../../support/assertions'
require_relative '../../../tools/encode_audio'
require_relative '../../../tools/support/release_files'
include GameRoomTest::Assertions

def assert(value, message = 'Assertion failed')
  @checks = @checks.to_i + 1
  super
end

def audio_output(*command)
  output, error, status = Open3.capture3(*command, binmode: true)
  raise "Countdown decoding failed: #{error}" unless status.success?
  output
end

root = File.expand_path('../../..', __dir__)
path = File.join(root, 'Audio/duck_countdown.opus')
ffmpeg, ffprobe = ENV.fetch('FFMPEG', 'ffmpeg'), ENV.fetch('FFPROBE', 'ffprobe')
before = Digest::SHA256.file(path).hexdigest
bytes = File.binread(path)
offset, granule, packets, packet = 0, nil, [], ''.b
while offset < bytes.bytesize
  assert_equal('OggS', bytes.byteslice(offset, 4))
  granule = bytes.byteslice(offset + 6, 8).unpack1('Q<')
  segment_count = bytes.getbyte(offset + 26)
  segments = bytes.byteslice(offset + 27, segment_count).bytes
  offset += 27 + segment_count
  segments.each do |size|
    packet << bytes.byteslice(offset, size)
    offset += size
    if size < 255
      packets << packet
      packet = ''.b
    end
  end
end
assert_equal(bytes.bytesize, offset)
assert(packet.empty?, 'The final Ogg packet is incomplete')
head, tags, *audio_packets = packets
assert(head.start_with?('OpusHead'))
assert(tags.start_with?('OpusTags'))
assert_equal(1, head.getbyte(9), 'The original mono recording was upmixed')
assert_equal(48_000, head.byteslice(12, 4).unpack1('V'))
pre_skip = head.byteslice(10, 2).unpack1('v')
decoded_samples = granule - pre_skip
assert_equal(102_336, decoded_samples, 'The trimmed countdown duration changed')

# Validate the packet duration from the Opus TOC, independently of container
# metadata. The last packet may be cropped by the final Ogg granule, as usual.
audio_packets.each do |data|
  config, code = data.getbyte(0) >> 3, data.getbyte(0) & 3
  frame_ms = if config >= 16
    Rational(5, 2) * (2 ** (config & 3))
  elsif config >= 12
    10 * (2 ** (config & 1))
  else
    [10, 20, 40, 60].fetch(config & 3)
  end
  frames = code.zero? ? 1 : (code == 3 ? data.getbyte(1) & 63 : 2)
  assert_equal(20, frame_ms * frames, 'Countdown no longer uses 20 ms Opus packets')
end
assert(audio_packets.map(&:bytesize).uniq.length > 1, 'Expected variable-bitrate Opus packets')
arguments = GameRoomAudioEncoding.arguments('original.ogg', 'new.opus')
{'-b:a' => '144k', '-vbr' => 'on', '-ar' => '48000', '-compression_level' => '10',
  '-frame_duration' => '20', '-application' => 'audio'}.each do |key, expected|
  assert_equal(expected, arguments.fetch(arguments.index(key) + 1))
end
assert((arguments & %w[-ac -af -ss -t -to]).empty?, 'The normal encoder unexpectedly alters or trims audio')

stream = JSON.parse(audio_output(ffprobe, '-v', 'error', '-show_streams', '-of', 'json', path)).fetch('streams')
assert_equal(1, stream.length)
assert_equal('opus', stream.first.fetch('codec_name'))
assert_equal('48000', stream.first.fetch('sample_rate'))
assert_equal(1, stream.first.fetch('channels'))
samples = audio_output(ffmpeg, '-v', 'error', '-nostdin', '-xerror', '-err_detect', 'explode',
  '-i', path, '-map', '0:a:0', '-f', 'f32le', '-').unpack('e*')
assert_equal(decoded_samples, samples.length, 'Decoded audio does not match the complete Opus granule')
assert(samples.all?(&:finite?))
assert(samples.map(&:abs).max > 0.1, 'The countdown has no audible content')
quiet_threshold = 10.0 ** (-45.0 / 20)
trailing_quiet_ms = samples.reverse.take_while { |value| value.abs < quiet_threshold }.length / 48.0
assert(trailing_quiet_ms < 15, 'The countdown has an unnecessary trailing silence')

notice = File.read(File.join(root, 'THIRD_PARTY_NOTICES.md'), encoding: 'UTF-8')
credit = notice.split('`Audio/duck_countdown.opus`', 2).last&.split('###', 2)&.first
assert(credit && credit.include?('Sadiquecat') && credit.include?('https://freesound.org/s/802499/'))
assert(credit.include?('CC0 1.0') && credit.include?('LICENSES/CC0-1.0.txt'))
assert(File.file?(File.join(root, 'LICENSES/CC0-1.0.txt')))
assert(GameRoomReleaseFiles.allowed?('Audio/duck_countdown.opus'))
assert(GameRoomReleaseFiles.allowed?('THIRD_PARTY_NOTICES.md'))
assert(GameRoomReleaseFiles.allowed?('LICENSES/CC0-1.0.txt'))
assert(!GameRoomReleaseFiles.allowed?('test/games/duck_racing/countdown_asset_test.rb'))
assert_equal(before, Digest::SHA256.file(path).hexdigest, 'Inspection changed the asset')

puts JSON.pretty_generate(status: 'PASS', checks: @checks,
  file: 'Audio/duck_countdown.opus', sha256: before, samples: decoded_samples,
  duration_ms: decoded_samples / 48.0, nominal_ceiling_ms: (Rational(decoded_samples, 48)).ceil,
  channels: 1, sample_rate: 48_000, audio_packets: audio_packets.length,
  trailing_quiet_ms_at_minus45db: trailing_quiet_ms, license: 'CC0 1.0', author: 'Sadiquecat')
