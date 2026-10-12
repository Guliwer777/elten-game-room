# frozen_string_literal: true

require_relative 'challenge_audio_helpers'
require_relative '../../support/host_source'
include DuckChallengeAudioTest

module DuckNativeAudioStatus
  # Use the actual host delegates. Each query obtains its own native status;
  # the test replaces only the asynchronously changing device boundary.
  path = EltenTestHost.file('src/eapi/audio/sound.rb')
  source = File.read(path, encoding: 'UTF-8')
  status = source[/^class SoundStatus\r?\n.*?^end\r?$/m]
  raise 'Native SoundStatus definition missing' unless status
  module_eval(status, path, source[0...source.index(status)].count("\n") + 1)

  class Sound < DuckChallengeAudioTest::Sound
    attr_accessor :script, :position_lag_ms
    attr_reader :status_reads

    def status
      @status_reads ||= []
      name = if @script && !@script.empty?
        @last_script = @script.shift
      elsif @last_script
        @last_script
      elsif @paused
        :paused
      else
        DuckChallengeAudioTest::Sound.instance_method(:playing?).bind_call(self) ? :playing : :stopped
      end
      @status_reads << name
      {playing: SoundStatus::Playing, stopped: SoundStatus::Stopped, paused: SoundStatus::Paused}.fetch(name)
    end

    def play
      @last_script, @script = nil, nil
      super
    end

    def position
      return super unless @position_lag_ms && @started
      [[(@program.now_ms - @started - @position_lag_ms) / 1000.0 * @frequency / 48_000, 0.0].max, length].min
    end
  end

  body = source[source.index(/^class Sound\r?$/)..]
  %w[playing? finished?].each do |name|
    code = body[/^  def #{Regexp.escape(name)}\r?\n.*?^  end\r?$/m]
    raise "Native Sound##{name} definition missing" unless code
    Sound.class_eval(code, path, source[0...source.index(code)].count("\n") + 1)
  end

  class Program < DuckChallengeAudioTest::Program
    def create_sound_from_asset(name, sample:, loop:)
      raise 'Wrong native stream contract' unless sample == false && loop == false
      sound = Sound.new(self, name)
      @sounds << sound
      sound
    end
  end
end

# The live failure's G input echo was naturally about 100 ms long. Native
# finished? can still see Playing while the following playing? sees Stopped.
program = DuckNativeAudioStatus::Program.new
program.duration_ms = 153.5
audio, _program, actions, errors = presenter(program)
assert(audio.feedback(sound: :simon, tone: 5))
sound = program.sounds.first
sound.status_reads.clear
sound.script = [:playing, :stopped]
at(audio, program, 108)
assert_equal([], errors, 'Natural completion between native status queries cancelled the challenge')
assert(audio.busy?, 'The recheck must leave final completion to the ordinary next UI step')
assert_equal([:playing, :stopped, :stopped], sound.status_reads)
assert_equal([], actions)
at(audio, program, 109)
assert(!audio.busy?)
assert_equal([], errors)
assert_equal([0], sound.seeks)
assert_equal(1, sound.plays)
audio.close

# The same boundary may occur during an important sequence, not only an
# input echo. Its position/time tail guard still precedes acknowledgment.
[0, 45].each do |position_lag|
  program = DuckNativeAudioStatus::Program.new
  program.duration_ms = 153.5
  audio, _program, actions, errors = presenter(program)
  audio.play(pulse(sound: :simon, tone: 5))
  at(audio, program, 0)
  sound = program.sounds.first
  sound.position_lag_ms = position_lag
  sound.script = [:playing, :stopped]
  at(audio, program, 108)
  assert_equal([], errors)
  assert_equal([:playback_started], actions.map { |action, _| action[:kind] })
  at(audio, program, 109)
  if position_lag.positive?
    assert(audio.busy?, 'The native device tail was skipped')
    assert_equal(1, actions.length)
    at(audio, program, 160)
  end
  assert(!audio.busy?)
  assert_equal([:playback_started, :playback_finished], actions.map { |action, _| action[:kind] })
  assert_equal(position_lag.positive? ? 160 : 109, actions.last.last)
  assert_equal([0], sound.seeks)
  assert_equal(1, sound.plays)
  assert_equal([], errors)
  audio.close
end

# A paused, closed or incomplete stream is not natural completion. These
# retain their existing errors, no successful acknowledgment and one cleanup.
{paused: :playback_interrupted, closed: :playback_failed,
  incomplete: :playback_interrupted}.each do |kind, error_code|
  program = DuckNativeAudioStatus::Program.new
  audio, _program, actions, errors = presenter(program)
  audio.play(pulse(sound: :simon, tone: 5))
  at(audio, program, 0)
  sound = program.sounds.first
  sound.pause if kind == :paused
  sound.close if kind == :closed
  sound.early_stop = true if kind == :incomplete
  at(audio, program, 110)
  if kind == :incomplete
    assert_equal([], errors)
    assert(audio.busy?)
    at(audio, program, 2_101)
  end
  assert_equal([error_code], errors.map(&:code))
  assert_equal([:playback_started], actions.map { |action, _| action[:kind] })
  assert(!audio.busy?)
  assert_equal([], program.managed)
  at(audio, program, 3_000)
  assert_equal(1, errors.length)
  audio.close
end

report('Duck native audio status transition, natural tail, pause, close and incomplete playback')
