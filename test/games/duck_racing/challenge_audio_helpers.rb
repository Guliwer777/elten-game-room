require_relative '../../support/assertions'
require_relative '../../../lib/duck_racing/challenge_audio'
require_relative '../../../games/duck_racing_support/audio_challenges'
require_relative '../../../games/duck_racing_support/challenge_engine'

module DuckChallengeAudioTest
  include GameRoomTest::Assertions
  MODEL = GameRoomDuckRacing::AudioChallenges
  PLAYER = GameRoomDuckRacing::ChallengeAudio

  class Sound
    attr_accessor :frequency, :pan, :volume, :stalled, :broken, :fail_start, :early_stop, :looped
    attr_reader :closes, :plays, :seeks, :asset
    def initialize(program, asset)
      @program, @frequency, @volume, @pan = program, 48_000.0, 1.0, 0.0
      @asset, @duration_ms = asset, program.durations.fetch(asset, program.duration_ms)
      @closes, @plays, @seeks = 0, 0, []
    end
    def opened?; !closed?; end
    def closed?; @closes > 0; end
    def length; @duration_ms / 1000.0; end
    def position=(value); @seeks << value; @position = value; end
    def position
      return 0.0 if @early_stop
      return @position.to_f unless @started
      [(@program.now_ms - @started) / 1000.0 * @frequency / 48_000, length].min
    end
    def playing?
      raise 'Broken audio device' if @broken
      !closed? && @started && !@paused && !@early_stop &&
        (@looped || @stalled || @program.now_ms - @started < @duration_ms * 48_000 / @frequency)
    end
    def finished?; closed? || @early_stop || @started && !@paused && !playing?; end
    def play
      return if @fail_start
      @started, @paused = @program.now_ms, false
      @plays += 1
      @program.events << {at: @started, frequency: @frequency, volume: @volume, pan: @pan, sound: self, asset: @asset}
    end
    def pause; @paused = true; end
    def close; @closes += 1; @paused = true; end
  end

  class Program
    class << self
      attr_accessor :settings
      def normalized_settings; @settings || {}; end
    end
    attr_accessor :now_ms, :duration_ms, :gain, :enabled, :missing, :next_sound
    attr_reader :sounds, :managed, :released, :events, :durations, :gains, :enabled_assets, :requested_assets
    def initialize
      @now_ms, @duration_ms, @gain, @enabled = 0, 150, 0.65, true
      @sounds, @managed, @released, @events = [], [], [], []
      @durations, @gains, @enabled_assets, @requested_assets = {}, {}, {}, []
      @durations[PLAYER::COUNTDOWN_ASSET] = GameRoomDuckRacing::ChallengeEngine::COUNTDOWN_MS
    end
    def create_sound_from_asset(name, sample:, loop:)
      ball = GameRoomAudioBall::SoundPack::PACKS.values.any? { |pack| pack.values_at('up', 'left', 'down').include?(name) }
      assets = [PLAYER::TONE_ASSET, PLAYER::QUACK_ASSET, PLAYER::COUNTDOWN_ASSET, PLAYER::SHOT_ASSET] +
        PLAYER::MEMORY_ASSETS + PLAYER::RHYTHM_ASSETS.values + %w[replay buzzer]
      raise 'Wrong sound-loading contract' unless (ball || assets.include?(name)) && sample == false && loop == ball
      @requested_assets << name
      return if @missing
      sound = Sound.new(self, name)
      sound.looped = loop
      @next_sound&.call(sound)
      @sounds << sound
      sound
    end
    def play_sound_from_asset(name, volume:)
      raise 'Unexpected decorative sound' unless GameRoomSounds::ASSET_NAMES.include?(name)
      sound = Sound.new(self, name)
      sound.volume = volume
      @sounds << sound
      sound.play
      sound
    end
    def manage(sound); @managed << sound; end
    def release(sound, close: false)
      @released << sound
      @managed.delete(sound)
      sound.close if close
    end
    private
    def game_room_sound_volume(name); @gains.fetch(name, @gain); end
    def game_room_sound_enabled?(name); @enabled_assets.fetch(name, @enabled); end
  end

  def assert(value, message = 'Assertion failed')
    @checks = @checks.to_i + 1
    super
  end

  def presenter(program = Program.new, &callback)
    actions, errors = [], []
    audio = PLAYER.new(program, clock_ms: -> { program.now_ms },
      on_action: ->(action, time) { actions << [action, time]; callback&.call(action, time) },
      on_error: ->(error) { errors << error })
    [audio, program, actions, errors]
  end

  def pulse(id: 1, sound: :quack, tone: nil, pan: nil, requested_ms: 0, offset_ms: 0, duration_ms: 250)
    {id: id, purpose: :test, requested_ms: requested_ms,
      events: [{sound: sound, tone: tone, pan: pan, offset_ms: offset_ms, duration_ms: duration_ms}]}
  end

  def at(audio, program, time)
    program.now_ms = time
    audio.step(time)
  end

  def drain(audio, program, step: 10, limit: 30_000)
    boundary = program.now_ms + limit
    while audio.busy? && program.now_ms < boundary
      at(audio, program, program.now_ms + step)
    end
    assert(!audio.busy?, 'Audio did not finish within the test boundary')
  end

  def report(name); puts "PASS #{name}: #{@checks} checks"; end
end
