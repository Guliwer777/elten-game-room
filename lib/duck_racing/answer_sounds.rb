# frozen_string_literal: true

require_relative '../../games/duck_racing_support/challenge_engine'
require_relative '../game_participants'

module GameRoomDuckRacing
  module AnswerSounds
    LOCAL_TYPES = %w[copy_number arithmetic race_question count_ducks guess_number].freeze

    module_function

    # Called only after an accepted local input. A finished trace rejects
    # further inputs, so refreshes cannot repeat this personal confirmation.
    def local_cue(trace)
      return unless trace.finished? && LOCAL_TYPES.include?(trace.state[:kind])

      result = ChallengeEngine.result_for(trace.state, trace.seat)
      correct = trace.state[:kind] == 'guess_number' ? result.dig(:best, :distance) == 0 : result[:correct] == true
      'duck_correct' if correct
    end

    # Sound ordering is shared: confirm the accepted solution, not an
    # optimistic swap. The event presenter owns replay/deduplication here.
    def result_cue(before_replay:, after_replay:, history:, viewer:)
      before, after = before_replay&.state, after_replay&.state
      return unless before.is_a?(Hash) && after.is_a?(Hash) && before[:session_id] == after[:session_id]
      challenge, result = before.dig(:round, :challenge), after[:last_resolution]
      return unless challenge && challenge[:kind] == 'sound_order' && result && result[:kind] == 'sound_order' &&
        result[:id] == challenge[:id] && !result[:cancelled]
      return unless history.any? { |entry| entry.kind == :challenge_result }

      seat = before_replay.players.index { |name| GameRoomParticipants.same?(name, viewer) }
      return unless !seat.nil? && challenge[:participants].include?(seat)

      'duck_correct' if result.dig(:results, seat, :correct) == true
    end
  end
end
