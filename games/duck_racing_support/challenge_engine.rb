# frozen_string_literal: true

require_relative "numeric_challenges"
require_relative "audio_challenges"
require_relative "quiz_challenge"
require_relative "settlement"
require_relative "challenges"

module GameRoomDuckRacing
  # One dispatch boundary for the pure challenge models. Resources are prepared
  # separately, never serialized into replay or constructed in an audio frame.
  module ChallengeEngine
    REALTIME = %w[audio_ball axel_pong].freeze
    SEQUENTIAL = (NumericChallenges::TURN_TYPES + %w[sound_memory]).freeze
    SHARED = (SEQUENTIAL + %w[sound_order]).freeze
    PRACTICE_TYPES = %w[simon hit_duck rhythm audio_ball axel_pong sound_memory].freeze
    FIRST_ANSWER = (NumericChallenges::ANSWER_TYPES + %w[count_ducks]).freeze
    SPEED_TYPES = FIRST_ANSWER
    LOCAL_SCORES = %w[simon rhythm hit_duck].freeze
    INDEPENDENT = (LOCAL_SCORES + %w[guess_number]).freeze
    COMPACT_PRIVATE = %w[guess_number rock_paper_scissors quiz].freeze
    PREPARATION_DELAY_MS = 5_000
    COUNT_DUCKS_PREPARATION_DELAY_MS = 3_000
    # Trimmed duck_countdown.opus duration; bots have no audio device.
    # Human input opens on actual playback completion, never on speech status.
    COUNTDOWN_MS = 2_132
    PREPARATION_MS = PREPARATION_DELAY_MS + COUNTDOWN_MS
    COUNT_DUCKS_PREPARATION_MS = COUNT_DUCKS_PREPARATION_DELAY_MS + COUNTDOWN_MS
    ORDER_PREPARATION_DELAY_MS = PREPARATION_DELAY_MS
    ORDER_PREPARATION_MS = ORDER_PREPARATION_DELAY_MS + COUNTDOWN_MS
    INPUT_KEYS = %w[kind value other press_id repeat playback_id onsets_ms].freeze
    INPUT_KINDS = %w[choose roll hit stand save answer take replay begin tone preview swap reveal target playback_started playback_finished]
      .to_h { |kind| [kind, kind.to_sym] }.freeze
    module_function

    def start(challenge, resources: {})
      kind = challenge.fetch(:kind)
      type = Challenges::BY_ID.fetch(kind)
      seats = challenge.fetch(:participants)
      unless seats.is_a?(Array) && seats.uniq == seats && seats.length.between?(type.minimum_players, type.maximum_players) &&
          seats.all? { |seat| seat.is_a?(Integer) && seat >= 0 }
        raise ArgumentError, "Invalid challenge participants"
      end
      common = {seats: seats, seed: challenge.fetch(:seed), now_ms: 0}
      # Sound ordering has a shared first-answer race. Neither public swaps
      # nor its 45-second limit begin before the common introduction and cue.
      common[:now_ms] = ORDER_PREPARATION_MS if kind == 'sound_order'
      model = if NumericChallenges::TYPES.key?(kind)
        racers = challenge.fetch(:race_snapshot).fetch(:racers)
        dice = seats.to_h { |seat| [seat, racers.fetch(seat).slice(:die_sides, :die_rolls)] }
        NumericChallenges.start(kind, **common, race_snapshot: challenge[:race_snapshot], dice: dice)
      elsif AudioChallenges::TYPES.value?(kind)
        AudioChallenges.start(kind, **common)
      elsif kind == "quiz"
        QuizChallenge.start(**common, questions: resources.fetch(:questions))
      else
        raise ArgumentError, "Realtime challenges require their native point adapter"
      end
      {kind: kind, participants: seats.dup, model: model,
        last_press: seats.to_h { |seat| [seat, 0] }, last_time: seats.to_h { |seat| [seat, 0] }}
    end

    def submit(state, seat:, action:, now_ms:, resources: {}, seed: nil)
      return false unless state[:participants].include?(seat) && now_ms.is_a?(Integer) && now_ms >= state[:last_time].fetch(seat)
      input = normalize_input(action)
      return false unless input
      return false if state[:kind] == 'sound_order' && input[:kind] != :swap
      return false if input.key?(:onsets_ms) && (state[:kind] != "rhythm" || input[:kind] != :playback_finished)
      acknowledgement = [:playback_started, :playback_finished].include?(input[:kind])
      unless acknowledgement
        return false unless input[:press_id].is_a?(Integer) && input[:press_id] > state[:last_press].fetch(seat)
      end
      engine = engine_for(state[:kind])
      arguments = {seat: seat, action: input, now_ms: now_ms}
      if seed
        return false unless seed.is_a?(Integer) && seed.between?(0, (1 << 128) - 1) &&
          %w[dice_duel risky_dice].include?(state[:kind]) && input[:kind] == :roll
        state[:model][:players].fetch(seat)[:random] = Random.new(seed)
      end
      return false unless engine.submit(state[:model], **arguments)

      state[:last_time][seat] = now_ms
      state[:last_press][seat] = input[:press_id] unless acknowledgement
      true
    end

    def expire(state, now_ms:, seed: nil)
      if seed && %w[dice_duel risky_dice].include?(state[:kind])
        return false unless seed.is_a?(Integer) && seed.between?(0, (1 << 128) - 1)
        # An expired turn can roll on behalf of more than one player. Their
        # independent streams must come from this receipt, not the challenge
        # seed which every participant has already seen.
        random = Random.new(seed)
        state[:participants].each do |seat|
          state[:model][:players].fetch(seat)[:random] = Random.new(random.rand(1 << 128))
        end
      end
      engine_for(state[:kind]).expire(state[:model], now_ms: now_ms)
    end

    def view(state, seat: nil, revealed: false)
      engine = engine_for(state[:kind])
      output = engine == AudioChallenges ? engine.view(state[:model], seat: seat) : engine.public_view(state[:model], viewer: seat)
      unless revealed
        # A local model reaching its deadline is not permission to disclose
        # the answer while another participant's commitment is unresolved.
        [:results, :answer, :outcome, :correct_index, :answers].each { |key| output.delete(key) }
        # Balls and their accepted picks are public throughout play. Their
        # running totals are inspectable, unlike independent private scores.
        output.delete(:scores) unless state[:kind] == 'numbered_balls'
        if state[:kind] == "guess_number" && output[:own]
          output[:own].delete(:best)
          output[:own][:attempts].each { |attempt| attempt.delete(:distance) }
        end
      end
      output
    end

    def stimulus(state, seat:)
      AudioChallenges.stimulus(state[:model], seat: seat) if engine_for(state[:kind]) == AudioChallenges
    end

    def current_turn(state)
      output = view(state)
      output.key?(:turn_seat) ? output[:turn_seat] : output.dig(:public, :turn)
    end

    def finished?(state)
      state[:model][:finished]
    end

    def own_finished?(state, seat)
      return false unless state[:participants].include?(seat)
      model = state[:model]
      engine = engine_for(state[:kind])
      if engine == NumericChallenges
        model[:players].fetch(seat)[:done]
      elsif engine == AudioChallenges
        model[:results].key?(seat)
      else
        model[:answers].key?(seat) || model[:finished]
      end
    end

    # Private, verified model output for final settlement, never a bot/view
    # projection. An unfinished attempt cannot be promoted to a result.
    def result_for(state, seat)
      raise ArgumentError, "The challenge attempt has not ended" unless own_finished?(state, seat)
      model, kind = state.values_at(:model, :kind)
      result = if NumericChallenges::TYPES.key?(kind)
        player = model[:players].fetch(seat)
        case kind
        when "rock_paper_scissors" then {choice: player[:choice]}
        when "guess_number" then {best: player[:best], attempts: player[:attempts].length}
        when *NumericChallenges::ANSWER_TYPES then {correct: player[:status] == :correct, answer: player[:attempts].last&.fetch(:value)}
        else {score: player[:total]}
        end
      elsif kind == "quiz"
        answer = model[:answers][seat]
        {correct: !answer.nil? && answer == model[:question][:correct_index], answer: answer}
      elsif kind == "count_ducks"
        {correct: !model[:scores].fetch(seat).nil?}
      elsif kind == "sound_order"
        model[:results].fetch(seat).slice(:correct, :misplaced)
      else
        {score: model[:scores].fetch(seat)}
      end
      Marshal.load(Marshal.dump(result))
    end

    def settlement(kind, balances:, results:, excluded: [], target: nil)
      unless results.is_a?(Hash) && results.keys.sort == balances.keys.sort &&
          excluded.is_a?(Array) && (excluded - balances.keys).empty?
        raise ArgumentError, "Incomplete challenge results"
      end
      scores = results.transform_values { |result| result[:score] }
      eligible = balances.keys - excluded
      case kind
      when "rock_paper_scissors"
        choices = results.transform_values { |result| result[:choice] }
        valid = choices.reject { |seat, choice| choice.nil? || excluded.include?(seat) }
        winner = valid.keys.first if valid.length == 1
        if valid.length == 2
          first, second = valid.keys
          difference = (NumericChallenges::CHOICES.index(valid[first]) - NumericChallenges::CHOICES.index(valid[second])) % 3
          winner = difference.zero? ? nil : (difference == 1 ? first : second)
        end
        Settlement.fixed(balances: balances, winner: winner, amount: 3, draw: valid.length == 2 && winner.nil?)
      when "guess_number"
        Settlement.guess_number(balances: balances, target: target,
          distances: results.transform_values { |result| result.dig(:best, :distance) }, eligible: eligible)
      when "blackjack", "risky_dice"
        Settlement.difference(balances: balances, scores: scores, ceiling: kind == "blackjack" ? 21 : 25, eligible: eligible)
      when *FIRST_ANSWER
        # Session settles as soon as the first verified correct attempt is
        # accepted in the server's ordered history. No client clock comparison.
        winners = results.select { |seat, result| result[:correct] == true && eligible.include?(seat) }.keys
        raise ArgumentError, "First-answer challenge has multiple winners" if winners.length > 1
        Settlement.fixed(balances: balances, winner: winners.first, amount: 4)
      when "sound_order"
        winners = results.select { |seat, result| result[:correct] == true && eligible.include?(seat) }.keys
        raise ArgumentError, 'Sound ordering has multiple winners' if winners.length > 1
        Settlement.sound_order(balances: balances, winner: winners.first,
          misplaced: results.transform_values { |result| result[:misplaced] })
      when "rhythm", "hit_duck"
        Settlement.accuracy(balances: balances, percentages: scores, eligible: eligible)
      when "quiz"
        Settlement.quiz(balances: balances, answers: results.to_h { |seat, result| [seat, result[:correct] == true && eligible.include?(seat)] })
      when "numbered_balls"
        Settlement.difference(balances: balances, scores: scores, eligible: eligible, max_transfer: 10)
      when "dice_duel", "simon", "sound_memory"
        Settlement.difference(balances: balances, scores: scores, eligible: eligible)
      else
        raise ArgumentError, "No settlement adapter for this challenge"
      end
    end

    # Called only when the challenge ends: after private reveals or the
    # first verified correct answer. Never exposed by an ongoing local view.
    def solution(challenge, resources: {})
      kind = challenge[:kind]
      return unless (NumericChallenges::ANSWER_TYPES + %w[guess_number count_ducks quiz]).include?(kind)
      model = start(challenge, resources: resources)[:model]
      case kind
      when "quiz" then model[:question][:choices].fetch(model[:question][:correct_index])
      when "count_ducks" then model[:private][:count]
      else model[:answer]
      end
    end

    # A genuinely missing reveal is not a fabricated positive result. The
    # settlement excludes that seat from winning; speed tasks use their limit.
    def missing_result(kind)
      case kind
      when "rock_paper_scissors" then {choice: nil}
      when "guess_number" then {best: nil, attempts: 0}
      when "quiz" then {correct: false, answer: nil}
      when *FIRST_ANSWER then {correct: false, answer: nil}
      when "sound_order" then {correct: false, misplaced: 8}
      else {score: 0}
      end
    end

    def engine_for(kind)
      return NumericChallenges if NumericChallenges::TYPES.key?(kind)
      return AudioChallenges if AudioChallenges::TYPES.value?(kind)
      return QuizChallenge if kind == "quiz"
      raise ArgumentError, "Unsupported challenge engine"
    end
    private_class_method :engine_for

    def normalize_input(action)
      return nil unless action.is_a?(Hash) && action.keys.all? { |key| INPUT_KEYS.include?(key.to_s) }
      input = action.to_h { |key, value| [key.to_s.to_sym, value] }
      return nil unless input.size == action.size && input[:repeat] != true
      kind = INPUT_KINDS[input[:kind].to_s]
      return nil unless kind
      input[:kind] = kind
      input
    end
    private_class_method :normalize_input
  end
end
