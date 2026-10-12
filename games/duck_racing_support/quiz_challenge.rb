# frozen_string_literal: true

require_relative "question_sets"

module GameRoomDuckRacing
  module QuizChallenge
    DURATION_MS = 20_000
    module_function

    def start(seats:, seed:, now_ms:, questions:)
      unless seats.is_a?(Array) && seats.length.between?(2, 8) && seats.uniq == seats &&
          seats.all? { |seat| seat.is_a?(Integer) && seat >= 0 } &&
          now_ms.is_a?(Integer) && now_ms >= 0 && questions.is_a?(QuestionSets::Prepared)
        raise ArgumentError, "Invalid race question setup"
      end
      {type: "quiz", seats: seats.dup, started_at_ms: now_ms, deadline_ms: now_ms + DURATION_MS,
        question: questions.draw(seed: seed), answers: {}, finished: false}
    end

    def submit(state, seat:, action:, now_ms:)
      return false if state[:finished] || !state[:seats].include?(seat) || state[:answers].key?(seat)
      return false unless now_ms.is_a?(Integer) && now_ms >= state[:started_at_ms] && now_ms < state[:deadline_ms]
      return false unless action[:kind] == :answer && action[:value].is_a?(Integer) && action[:value].between?(0, 3)

      state[:answers][seat] = action[:value]
      state[:finished] = state[:answers].length == state[:seats].length
      true
    end

    def expire(state, now_ms:)
      return false if state[:finished] || !now_ms.is_a?(Integer) || now_ms < state[:deadline_ms]

      state[:finished] = true
      true
    end

    def public_view(state, viewer:)
      output = {type: "quiz", question: QuestionSets.public_view(state[:question]),
        seats: state[:seats].dup, deadline_ms: state[:deadline_ms], finished: state[:finished],
        answered: state[:seats].to_h { |seat| [seat, state[:answers].key?(seat)] }}
      output[:own_answer] = state[:answers][viewer] if state[:answers].key?(viewer)
      if state[:finished]
        output[:correct_index] = state[:question][:correct_index]
        output[:answers] = state[:answers].dup
      end
      output
    end
  end
end
