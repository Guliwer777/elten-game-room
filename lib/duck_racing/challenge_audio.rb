# frozen_string_literal: true

require_relative '../game_sound_output'
require_relative '../audio_ball/sound_pack'

module GameRoomDuckRacing
  # Local presentation, driven by the owning client's existing UI step. One
  # instance belongs to one challenge and one local listener. It never scores,
  # sleeps, reads keys, advances a remote clock or owns a background timer.
  class ChallengeAudio
    TONE_ASSET = 'duck_note_c'
    QUACK_ASSET = 'duck_quack'
    COUNTDOWN_ASSET = 'duck_countdown'
    PITCH_STEPS = [0, 2, 4, 5, 7, 9, 11, 12].freeze
    # The source is middle C (C4); digits 1–5 play C, D, E, F and G.
    SIMON_STEPS = [0, 2, 4, 5, 7].freeze
    MEMORY_ASSETS = %w[duck_memory_bark duck_memory_bell duck_memory_drop
      duck_memory_clap duck_memory_zip].freeze
    RHYTHM_ASSETS = {'f' => 'duck_rhythm_f', 'j' => 'duck_rhythm_j'}.freeze
    FEEDBACK_LIMIT = 32

    class PlaybackError < StandardError
      attr_reader :code
      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    attr_reader :error

    def initialize(program, on_action:, on_error:, on_announcement: nil,
      clock_ms: -> { (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).floor })
      @program, @on_action, @on_error, @clock_ms = program, on_action, on_error, clock_ms
      @on_announcement = on_announcement
      @handles, @playing, @feedback = {}, {}, []
      @last_playback_id, @last_sound_event_id, @last_ms = 0, 0, nil
      @closed, @stepping = false, false
    end

    # Pass the result of AudioChallenges.stimulus. Repeated snapshots are
    # harmless. nil stops only obsolete private playback, not queued reveals.
    def play(stimulus)
      return false if @closed || @error
      if stimulus.nil?
        changed = !@sequence.nil?
        stop_voice(:sequence)
        @sequence = nil
        return changed
      end
      descriptor = normalize_playback(stimulus)
      return false if descriptor[:id] <= @last_playback_id

      stop_voice(:sequence)
      @last_playback_id = descriptor[:id]
      @sequence = {descriptor: descriptor, index: 0, onsets: []}
      true
    rescue PlaybackError => error
      fail_playback(error)
    end

    # Call for EVERY accepted memory reveal or pitch swap, not only the last
    # public snapshot. Keep rapid reveals and both swapped tones in order.
    def sound_event(event)
      return false if @closed || @error
      unless event.is_a?(Hash) && event[:id].is_a?(Integer) && event[:id] > 0 && [:memory, :pitch].include?(event[:sound])
        raise ArgumentError, 'Invalid challenge sound event'
      end
      tones = event[:sound] == :pitch ? event[:tones] : [event[:tone]]
      raise ArgumentError, 'Invalid swapped sounds' unless tones.is_a?(Array) && tones.length == (event[:sound] == :pitch ? 2 : 1)
      cues = tones.map { |tone| normalize_cue(event.merge(tone: tone, offset_ms: 0, duration_ms: 200)) }
      if event[:sound] == :memory
        cues.first[:announcement] = event[:announcement]
        if event.key?(:matched)
          raise ArgumentError, 'Invalid memory result' unless event[:matched] == true || event[:matched] == false
          cues << normalize_cue(sound: event[:matched] ? :correct : :wrong, offset_ms: 0, duration_ms: 200)
            .merge(announcement: event[:result_announcement])
        end
      end
      return false if event[:id] <= @last_sound_event_id
      return fail_playback(PlaybackError.new(:queue_overflow, 'Too many unheard challenge sounds')) if @feedback.length + cues.length > FEEDBACK_LIMIT

      @feedback.concat(cues)
      @last_sound_event_id = event[:id]
      true
    end

    # Unscored local practice/inspection. Only the normal UI step drives it.
    def preview(sound:, tone: nil, pan: nil)
      play(id: @last_playback_id + 1, requested_ms: @clock_ms.call,
        events: [{sound: sound, tone: tone, pan: pan, offset_ms: 0,
          duration_ms: sound == :audio_ball ? 2_000 : 200}])
    end

    # Echo an already accepted human input. The model, not this presenter,
    # filters held keys/repeats and decides whether input is currently legal.
    def feedback(sound:, tone:)
      return false if @closed || @error || @sequence
      raise ArgumentError, 'Invalid challenge feedback' unless [:rhythm, :simon].include?(sound)
      cue = normalize_cue(sound: sound, tone: tone, offset_ms: 0, duration_ms: 150)
      now_ms = @clock_ms.call
      validate_time(now_ms)
      # Input echo is immediate, like a pressed musical key. Releasing the
      # previous echo avoids a backlog and imposes no limit on Simon's level.
      # Public memory reveals instead use their lossless sequential queue.
      stop_voice(:feedback)
      start_voice(:feedback, cue, now_ms)
      true
    rescue PlaybackError => error
      fail_playback(error)
    end

    def busy?
      !@closed && !@error && (!@sequence.nil? || !@playing.empty? || !@feedback.empty?)
    end

    # Lets the shared presentation queue wait for transient feedback without
    # writing hints to history or depending on a speech synthesizer's status.
    def finished?; !busy?; end

    def step(now_ms = @clock_ms.call)
      return false if @closed || @error || @stepping
      validate_time(now_ms)
      @last_ms = now_ms
      @stepping = true
      begin
        advance_voice(:sequence, now_ms)
        advance_voice(:feedback, now_ms)
        advance_sequence(now_ms)
        start_voice(:feedback, @feedback.shift, now_ms) if !@playing[:feedback] && !@feedback.empty?
        true
      rescue PlaybackError => error
        fail_playback(error)
      ensure
        @stepping = false
      end
    end

    def close
      return if @closed
      @closed = true
      clear_playback
      @handles.each_value { |entry| release_handle(entry[:sound]) }
      @handles.clear
    end

    private

    def normalize_playback(value)
      unless value.is_a?(Hash) && value[:id].is_a?(Integer) && value[:id] > 0 &&
          value[:requested_ms].is_a?(Integer) && value[:requested_ms] >= 0 &&
          value[:events].is_a?(Array) && !value[:events].empty?
        raise ArgumentError, 'Invalid challenge playback'
      end
      cues = value[:events].map { |event| normalize_cue(event) }
      unless cues.first[:offset_ms].zero? && cues.each_cons(2).all? { |left, right| left[:offset_ms] < right[:offset_ms] }
        raise ArgumentError, 'Invalid challenge playback order'
      end
      {id: value[:id], requested_ms: value[:requested_ms], events: cues}
    end

    def normalize_cue(value)
      unless value.is_a?(Hash) && value[:offset_ms].is_a?(Integer) && value[:offset_ms] >= 0 &&
          value[:duration_ms].is_a?(Integer) && value[:duration_ms] > 0
        raise ArgumentError, 'Invalid challenge sound cue'
      end
      tone, pan, semitones = value[:tone], 0.0, 0
      case value[:sound]
      when :quack, :countdown, :correct, :wrong
      when :target
        pan = value[:pan]
        raise ArgumentError, 'Invalid challenge stereo position' unless pan.is_a?(Numeric) && pan.finite? && pan.between?(-1, 1)
      when :rhythm
        raise ArgumentError, 'Invalid rhythm tone' unless RHYTHM_ASSETS.key?(tone)
      when :pitch
        raise ArgumentError, 'Invalid ordered tone' unless tone.is_a?(Integer) && tone.between?(1, 8)
        semitones = PITCH_STEPS.fetch(tone - 1)
      when :simon
        raise ArgumentError, 'Invalid memory tone' unless tone.is_a?(Integer) && tone.between?(1, 5)
        semitones = SIMON_STEPS.fetch(tone - 1)
      when :memory
        raise ArgumentError, 'Invalid memory sound' unless tone.is_a?(Integer) && tone.between?(1, MEMORY_ASSETS.length)
      when :audio_ball
        raise ArgumentError, 'Invalid ball preview' unless %w[up left down].include?(tone)
      else raise ArgumentError, 'Unknown challenge sound'
      end
      asset = case value[:sound]
      when :quack, :target then QUACK_ASSET
      when :countdown then COUNTDOWN_ASSET
      when :rhythm then RHYTHM_ASSETS.fetch(tone)
      when :memory then MEMORY_ASSETS.fetch(tone - 1)
      when :correct then 'replay'
      when :wrong then 'buzzer'
      when :audio_ball then GameRoomAudioBall::SoundPack.asset(tone, @program)
      else TONE_ASSET
      end
      {sound: value[:sound], asset: asset, ratio: 2.0**(semitones / 12.0), pan: pan.to_f,
        offset_ms: value[:offset_ms], duration_ms: value[:duration_ms],
        limit_ms: value[:sound] == :audio_ball ? 2_000 : nil}
    end

    def validate_time(now_ms)
      unless now_ms.is_a?(Integer) && now_ms >= 0 && (@last_ms.nil? || now_ms >= @last_ms)
        raise ArgumentError, 'Challenge audio needs a monotonic millisecond clock'
      end
    end

    def actual_time(now_ms)
      actual = @clock_ms.call
      unless actual.is_a?(Integer) && actual >= now_ms
        raise ArgumentError, 'Challenge audio clocks disagree'
      end
      @last_ms = actual
    end

    def advance_sequence(now_ms)
      sequence = @sequence
      return unless sequence
      descriptor, index = sequence.values_at(:descriptor, :index)
      cues = descriptor[:events]
      if index == cues.length
        return if @playing[:sequence]
        @sequence = nil
        action = {kind: :playback_finished, playback_id: descriptor[:id]}
        action[:onsets_ms] = sequence[:onsets].dup if cues.all? { |cue| cue[:sound] == :rhythm }
        @on_action.call(action, actual_time(now_ms))
        return
      end
      return if @playing[:sequence]
      return if index.zero? && (@playing[:feedback] || !@feedback.empty?)
      # A delayed UI frame must not compress the remaining sounds together.
      # Rhythm scoring receives these actual onsets rather than a made-up
      # nominal rhythm. Other tasks keep the full audible sequence as well.
      due = index.zero? ? descriptor[:requested_ms] :
        sequence[:onsets].last + cues[index][:offset_ms] - cues[index - 1][:offset_ms]
      return if now_ms < due
      started = start_voice(:sequence, cues[index], now_ms)
      sequence[:onsets] << started
      sequence[:index] += 1
      @on_action.call({kind: :playback_started, playback_id: descriptor[:id]}, started) if index.zero?
    end

    def handle_for(role, asset)
      key = [role, asset]
      return @handles[key] if @handles.key?(key)
      sound = audio_call { @program.create_sound_from_asset(asset, sample: false, loop: asset.start_with?('audio_ball_')) }
      raise PlaybackError.new(:asset_unavailable, 'Cannot open the challenge sound') unless sound
      begin
        @program.manage(sound)
        required = [:frequency, :frequency=, :pan=, :position=, :volume=, :play, :pause, :playing?, :finished?, :length]
        unless required.all? { |method| sound.respond_to?(method) } && (!sound.respond_to?(:opened?) || sound.opened?)
          raise PlaybackError.new(:asset_unavailable, 'Challenge sound is not a usable stream')
        end
        frequency, length = sound.frequency.to_f, sound.length.to_f
        unless frequency.finite? && frequency.positive? && length.finite? && length.positive?
          raise PlaybackError.new(:asset_unavailable, 'Challenge sound has invalid format or length')
        end
        @handles[key] = {sound: sound, asset: asset, frequency: frequency, length: length}
      rescue StandardError
        release_handle(sound)
        raise
      end
    end

    def start_voice(role, cue, now_ms)
      entry = audio_call { handle_for(role, cue[:asset]) }
      sound = entry[:sound]
      started = audio_call do
        sound.frequency = entry[:frequency] * cue[:ratio]
        sound.pan = cue[:pan]
        sound.position = 0
        GameRoomSoundOutput.apply(@program, sound, shared_volume(entry[:asset]), restart: true)
        sound.play
        raise PlaybackError.new(:playback_failed, 'Challenge sound did not start') unless sound.playing?
        actual_time(now_ms)
      end
      # This is only a failure bound, not a substitute for finished?. A muted
      # stream still plays at volume zero and finishes normally on the device.
      duration = (entry[:length] / cue[:ratio] * 1000).ceil
      @playing[role] = {sound: sound, asset: entry[:asset], started_ms: started, duration_ms: duration,
        length: entry[:length], deadline_ms: started + duration + 2_000, limit_ms: cue[:limit_ms]}
      @on_announcement&.call(cue[:announcement]) unless cue[:announcement].to_s.empty?
      started
    end

    def advance_voice(role, now_ms)
      voice = @playing[role]
      return unless voice
      sound = voice[:sound]
      audio_call do
        if sound.respond_to?(:closed?) && sound.closed?
          raise PlaybackError.new(:playback_failed, 'Challenge sound was closed during playback')
        end
        if voice[:limit_ms]
          GameRoomSoundOutput.apply(@program, sound, shared_volume(voice[:asset]))
          stop_voice(role) if now_ms >= voice[:started_ms] + voice[:limit_ms]
          return
        end
        if sound.finished?
          awaiting_tail = now_ms < voice[:started_ms] + voice[:duration_ms] - 20
          awaiting_tail ||= sound.respond_to?(:position) && sound.position.to_f < voice[:length] - 0.02
          if awaiting_tail
            # BASS may stop decoding before buffered samples reach the device.
            # Its playback position keeps advancing during that natural tail.
            # Wait on ordinary UI steps; neither acknowledge nor restart it.
            # A genuinely stopped, incomplete sound still hits the same bound.
            if now_ms >= voice[:deadline_ms]
              raise PlaybackError.new(:playback_interrupted, 'Challenge sound stopped before its end')
            end
            GameRoomSoundOutput.apply(@program, sound, shared_volume(voice[:asset]))
            return
          end
          @playing.delete(role)
        elsif now_ms >= voice[:deadline_ms]
          raise PlaybackError.new(:playback_stalled, 'Challenge sound did not finish')
        elsif !sound.playing? && !sound.finished?
          # These native status reads are separate. Natural completion can
          # happen between them; the next ordinary step checks its tail.
          raise PlaybackError.new(:playback_interrupted, 'Challenge sound was interrupted')
        else
          GameRoomSoundOutput.apply(@program, sound, shared_volume(voice[:asset]))
        end
      end
    end

    def shared_volume(asset)
      return 0.0 if @program.respond_to?(:game_room_sound_enabled?, true) &&
        !@program.send(:game_room_sound_enabled?, asset)
      volume = @program.respond_to?(:game_room_sound_volume, true) ? @program.send(:game_room_sound_volume, asset).to_f : 1.0
      raise PlaybackError.new(:invalid_volume, 'Invalid challenge sound volume') unless volume.finite?
      [[volume, 0.0].max, 1.0].min
    end

    def audio_call
      yield
    rescue PlaybackError
      raise
    rescue StandardError => error
      raise PlaybackError.new(:audio_error, "#{error.class}: #{error.message}")
    end

    def stop_voice(role)
      voice = @playing.delete(role)
      audio_call { voice[:sound].pause } if voice
    end

    def clear_playback
      @sequence = nil
      @feedback.clear
      @playing.keys.each do |role|
        stop_voice(role)
      rescue PlaybackError
        # The original failure is reported once. All handles are still
        # released below; a failed cleanup must not leave a playable queue.
      end
    end

    def release_handle(sound)
      @program.release(sound, close: true)
    rescue StandardError => release_error
      begin
        sound.close if sound.respond_to?(:close)
      rescue StandardError => close_error
        Log.warning("Duck challenge sound cleanup: #{release_error.message}; #{close_error.message}") if defined?(Log)
      end
    end

    def fail_playback(error)
      return false if @error
      @error = error
      close
      @on_error.call(error)
      false
    end
  end
end
