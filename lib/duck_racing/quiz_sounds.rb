# frozen_string_literal: true

require_relative '../game_sounds'

module GameRoomDuckRacing
  # The timer uses the attempt's existing elapsed clock and public view.
  # Answer feedback belongs exclusively to the accepted reveal transition.
  class QuizSounds
    def initialize(program)
      @program = program
      reset
    end

    def reset
      @warned = false
    end

    def tick(view, seat:, now_ms:)
      return if @warned || !view.is_a?(Hash) || view[:type] != 'quiz'
      return unless view[:seats].to_a.include?(seat)
      return if view[:finished] || view.dig(:answered, seat) || view.dig(:own, :done)
      return unless now_ms.is_a?(Integer) && now_ms >= 0 && view[:deadline_ms].is_a?(Integer)
      remaining = view[:deadline_ms] - now_ms
      return unless remaining.positive? && remaining <= 5_000

      # Even a muted/disabled cue is consumed; returning to the game must not
      # play a late warning that no longer describes the current deadline.
      @warned = true
      GameRoomSounds.play(@program, 'buzzer2')
    end

    def self.result_cue(before_replay:, after_replay:, history:, viewer:)
      before, after = before_replay&.state, after_replay&.state
      return unless before.is_a?(Hash) && after.is_a?(Hash) && before[:session_id] == after[:session_id]
      challenge = before.dig(:round, :challenge)
      result = after[:last_resolution]
      return unless challenge && challenge[:kind] == 'quiz' && result && result[:kind] == 'quiz' &&
        result[:id] == challenge[:id] && !result[:cancelled]
      return unless history.any? { |entry| entry.kind == :challenge_details }

      seat = before_replay.players.index { |name| GameRoomParticipants.same?(name, viewer) }
      return unless !seat.nil? && challenge[:participants].include?(seat)
      answer = result[:results]&.[](seat)
      return unless answer

      answer[:correct] == true ? 'replay' : 'quiz_wrong_answer'
    end
  end
end
