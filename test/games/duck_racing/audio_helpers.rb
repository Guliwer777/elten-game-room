require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/audio_challenges"

module GameRoomTest
  module DuckAudio
    include Assertions

    AUDIO = GameRoomDuckRacing::AudioChallenges

    def assert(value, message = "Assertion failed")
      @duck_audio_checks = (@duck_audio_checks || 0) + 1
      super
    end

    def audio_start(type, seed: 31, seats: ["A", "B"], now_ms: 0)
      AUDIO.start(type, seats: seats, seed: seed, now_ms: now_ms)
    end

    def audio_player(state, seat)
      state.fetch(:private).fetch(:players).fetch(seat)
    end

    def audio_press(state, seat, kind, now_ms, **fields)
      action = {kind: kind, press_id: audio_player(state, seat)[:press_id] + 1}.merge(fields)
      AUDIO.submit(state, seat: seat, action: action, now_ms: now_ms)
    end

    def audio_ack(state, seat, now_ms, kind: :playback_finished, playback_id: nil)
      playback_id ||= AUDIO.stimulus(state, seat: seat)&.fetch(:id)
      AUDIO.submit(state, seat: seat, action: {kind: kind, playback_id: playback_id}, now_ms: now_ms)
    end

    def audio_reject(state)
      before = Marshal.dump(state)
      assert_equal(false, yield)
      assert_equal(before, Marshal.dump(state), "Rejected input mutated challenge state")
    end

    def audio_simon_level(state, seat, now_ms)
      playback = AUDIO.stimulus(state, seat: seat)
      events = playback.fetch(:events)
      # The synthetic playback duration grows well beyond five seconds.
      now_ms = [now_ms, playback.fetch(:requested_ms)].max +
        events.last[:offset_ms] + events.last[:duration_ms]
      assert(audio_ack(state, seat, now_ms), "Simon playback did not finish")
      events.each do |event|
        now_ms += 100
        assert(audio_press(state, seat, :tone, now_ms, value: event[:tone]))
      end
      now_ms
    end

    def audio_report(label)
      puts "PASS #{label}: #{@duck_audio_checks} checks"
    end
  end
end
