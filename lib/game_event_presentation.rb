# Local presentation only: persisted events and network recovery never wait here.
# The screen advances this queue from its existing form timer, without sleeping.
class GameRoomEventPresentation
  Step = Struct.new(:replay, :start, :finish, :defer_replay, :delay, :wait_for_sounds, keyword_init: true)
  attr_reader :visible_replay, :revision

  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, initial_replay: nil)
    @clock = clock
    @visible_replay = initial_replay
    @queue = []
    @sounds = []
    @current = nil
    @revision = 0
  end

  def enqueue(replay:, start:, finish: nil, defer_replay: false, delay: 0.0, wait_for_sounds: true)
    raise ArgumentError, 'Invalid presentation delay' unless delay.is_a?(Numeric) && delay.finite? && delay >= 0
    @queue << Step.new(replay: replay, start: start, finish: finish, defer_replay: defer_replay,
      delay: delay, wait_for_sounds: wait_for_sounds)
  end

  def busy?
    @current != nil || !@queue.empty?
  end

  def advance
    previous = @revision
    loop do
      if @current != nil
        return @revision != previous if @clock.call < @ready_at || @current.wait_for_sounds && sounds_playing?

        step = @current
        @current = nil
        @sounds = []
        @visible_replay = step.replay if step.defer_replay
        @revision += 1
        step.finish&.call
      end
      break if @queue.empty?

      @current = @queue.shift
      @visible_replay = @current.replay unless @current.defer_replay
      @revision += 1
      @sounds = Array(@current.start.call).select { |sound| sound.respond_to?(:finished?) }
      @ready_at = @clock.call + @current.delay
      # Only an emergency limit for a broken device/handle. Normal sequencing
      # follows finished?, not a guessed duration or a wall-clock timestamp.
      lengths = @sounds.map do |sound|
        value = sound.respond_to?(:length) ? sound.length.to_f : 0.0
        value.finite? && value > 0 ? [value + 2.0, 120.0].min : 30.0
      rescue StandardError
        30.0
      end
      @deadline = @clock.call + (lengths.max || 0.0)
    end
    @revision != previous
  end

  def close
    @queue.clear
    @sounds.each { |sound| close_sound(sound) }
    @sounds = []
    @current = nil
    @visible_replay = nil
    @revision += 1
  end

  private

  def sounds_playing?
    playing = @sounds.select do |sound|
      !sound.finished?
    rescue StandardError
      close_sound(sound)
      false
    end
    return false if playing.empty?
    return true if @clock.call < @deadline

    playing.each { |sound| close_sound(sound) }
    Log.warning("ELTEN Game Room released a stalled presentation sound") if defined?(Log)
    false
  end

  def close_sound(sound)
    sound.close if sound.respond_to?(:close)
  rescue StandardError
    nil
  end
end
