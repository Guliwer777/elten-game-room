# frozen_string_literal: true

# Prepare the approved joesh2 C4 recording for the existing 150 ms note
# slot. The short fade avoids a hard cut; runtime still transposes C4.
# Keep the downloaded source outside Audio/. This tool never overwrites.
require 'tmpdir'
require 'open3'
require_relative 'encode_audio'

abort 'Usage: ruby tools/prepare-duck-marimba.rb SOURCE NEW.opus [FFMPEG FFPROBE]' unless (2..4).cover?(ARGV.length)
source, target, ffmpeg, ffprobe = ARGV
ffmpeg ||= 'ffmpeg'
ffprobe ||= 'ffprobe'
raise "Refusing to overwrite audio: #{target}" if File.exist?(target)
Dir.mktmpdir('gr-duck-marimba-') do |temporary|
  prepared = File.join(temporary, 'c4.wav')
  _out, error, status = Open3.capture3(ffmpeg, '-v', 'error', '-nostdin', '-i', source,
    '-map', '0:a:0', '-map_metadata', '0', '-af',
    'atrim=end=0.150,asetpts=PTS-STARTPTS,afade=t=in:d=0.002,afade=t=out:st=0.110:d=0.040',
    '-c:a', 'pcm_s24le', '-metadata', 'title=C4 marimba (short game note)',
    '-metadata', 'artist=joesh2', '-metadata',
    'comment=https://freesound.org/people/joesh2/sounds/577691/; CC0 1.0; 150 ms excerpt with edge fades',
    prepared)
  raise "Cannot prepare marimba: #{error}" unless status.success?
  GameRoomAudioEncoding.encode(prepared, target, ffmpeg: ffmpeg, ffprobe: ffprobe)
end
puts 'Prepared marimba C4: original channels and level, 150 ms, Opus 144 kb/s VBR.'
