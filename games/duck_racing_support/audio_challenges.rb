# frozen_string_literal: true

require_relative "../../lib/game_random"

module GameRoomDuckRacing
  # Pure challenge models. `private` is authoritative/local material, not a
  # public snapshot or bot input. The integration layer must bind actions to
  # the challenge/controller and supply locally measured elapsed times; these
  # models neither read clocks nor compare clocks belonging to different PCs.
  module AudioChallenges
    TYPES = {
      22 => "count_ducks", 24 => "rhythm", 25 => "sound_order",
      26 => "simon", 27 => "sound_memory", 28 => "hit_duck"
    }.freeze

    module_function

    def start(type_id, seats:, seed:, now_ms:)
      type = TYPES[type_id] || TYPES.values.find { |value| value == type_id.to_s }
      raise ArgumentError, "Unknown audio challenge" unless type
      unless seats.is_a?(Array) && seats.length.between?(2, type == "sound_memory" ? 2 : 8) &&
          seats.uniq.length == seats.length && seats.all? { |seat| seat.is_a?(Integer) || (seat.is_a?(String) && !seat.empty?) }
        raise ArgumentError, "Invalid challenge seats"
      end
      raise ArgumentError, "Invalid challenge seed or time" unless seed.is_a?(Integer) && valid_time?(now_ms)

      seats = seats.map { |seat| seat.is_a?(String) ? seat.dup.freeze : seat }.freeze
      state = {
        type: type, seats: seats, started_ms: now_ms, finished: false,
        scores: {}, results: {}, public: {},
        private: {seed: seed, players: seats.to_h { |seat| [seat, new_player(now_ms)] }}
      }
      random = Random.new(seed)
      case type
      when "count_ducks" then start_count(state, random, now_ms)
      when "rhythm" then start_rhythm(state, random, now_ms)
      when "sound_order" then start_order(state, random, now_ms)
      when "simon" then start_simon(state, now_ms)
      when "sound_memory" then start_memory(state, random, now_ms)
      when "hit_duck" then start_targets(state, random, now_ms)
      end
      state
    end

    # Every keyboard command represents a distinct down edge, not a held key.
    # Its monotonic press_id prevents duplicate delivery becoming a new choice.
    # Playback acknowledgements instead name the outstanding playback_id.
    # A rejected input leaves all state, including random material, unchanged.
    def submit(state, seat:, action:, now_ms:)
      return false if state[:finished] || !state[:seats].include?(seat) || !action.is_a?(Hash) || !valid_time?(now_ms)

      player = players(state).fetch(seat)
      return false if player[:phase] == :finished || now_ms < player[:last_ms]
      return false if player[:deadline_ms] && now_ms >= player[:deadline_ms]
      return false if state[:type] == "sound_memory" && now_ms >= state[:public][:deadline_ms]

      kind = action[:kind]
      if action.key?(:onsets_ms)
        return false unless state[:type] == "rhythm" && kind == :playback_finished
      end
      acknowledgement = [:playback_finished, :playback_started].include?(kind)
      unless acknowledgement
        press_id = action[:press_id]
        return false unless press_id.is_a?(Integer) && press_id > player[:press_id] && action[:repeat] != true
      end
      accepted = if acknowledgement
        acknowledge_playback(state, seat, action, now_ms)
      else
        case state[:type]
        when "count_ducks" then submit_count(state, seat, action, now_ms)
        when "rhythm" then submit_rhythm(state, seat, action, now_ms)
        when "sound_order" then submit_order(state, seat, action, now_ms)
        when "simon" then submit_simon(state, seat, action, now_ms)
        when "sound_memory" then submit_memory(state, seat, action, now_ms)
        when "hit_duck" then submit_target(state, seat, action, now_ms)
        end
      end
      return false unless accepted

      player[:press_id] = action[:press_id] unless acknowledgement
      player[:last_ms] = now_ms
      true
    end

    # Timeouts are explicit transitions, not a side effect of rejected input.
    # Playback failures/disconnections belong to the outer lifecycle. In
    # particular, Simon has no timeout while a sequence is still being heard.
    def expire(state, now_ms:)
      return false if state[:finished] || !valid_time?(now_ms) || now_ms < state[:started_ms]
      return expire_memory(state, now_ms) if state[:type] == "sound_memory"
      if state[:type] == 'sound_order'
        return false if now_ms < state[:started_ms] + 45_000
        finish_order(state, nil, state[:started_ms] + 45_000)
        return true
      end

      changed = false
      players(state).each do |seat, player|
        deadline = player[:deadline_ms]
        next unless deadline && now_ms >= deadline && player[:phase] != :finished

        case state[:type]
        when "count_ducks"
          finish_player(state, seat, nil, :timeout, deadline)
        when "rhythm"
          finish_rhythm(state, seat, :timeout, deadline)
        when "simon"
          finish_player(state, seat, player[:completed_length], :timeout, deadline)
        when "hit_duck"
          complete_target(state, seat, 0, :timeout, deadline)
        end
        player[:last_ms] = [player[:last_ms], deadline].max
        changed = true
      end
      changed
    end

    # No seed, expected answer, opponent's response or future target/sequence
    # is exposed. Only the player's own pending audio is returned by stimulus.
    def view(state, seat: nil)
      output = {
        type: state[:type], seats: state[:seats].dup, started_ms: state[:started_ms],
        finished: state[:finished], public: copy(state[:public]),
        completed: players(state).to_h { |participant, player| [participant, player[:phase] == :finished] }
      }
      output[:answer_digits] = state[:private][:count].to_s.length if state[:type] == "count_ducks"
      if state[:finished]
        output[:scores] = copy(state[:scores])
        output[:results] = copy(state[:results])
      end
      if state[:seats].include?(seat)
        player = players(state).fetch(seat)
        output[:own] = {
          phase: player[:phase], deadline_ms: player[:deadline_ms],
          playback_id: player[:playback] && player[:playback][:id]
        }
        [:attempts, :replays_left, :level, :completed_length, :input_index, :target_index].each do |key|
          output[:own][key] = player[key] if player.key?(key)
        end
        output[:own][:result] = copy(state[:results][seat]) if state[:results].key?(seat)
        output[:own][:last_target_score] = player[:target_scores].last if state[:type] == 'hit_duck'
        output[:own][:arrangement] = player[:arrangement].dup if state[:type] == 'sound_order'
      end
      output
    end

    def stimulus(state, seat:)
      return nil unless state[:seats].include?(seat)

      copy(players(state).fetch(seat)[:playback])
    end

    def valid_time?(value)
      value.is_a?(Integer) && value >= 0
    end
    private_class_method :valid_time?

    def new_player(now_ms)
      {phase: :ready, deadline_ms: nil, last_ms: now_ms, press_id: -1, playback_serial: 0, playback: nil}
    end
    private_class_method :new_player

    def players(state)
      state.fetch(:private).fetch(:players)
    end
    private_class_method :players

    def copy(value)
      case value
      when Hash then value.to_h { |key, item| [copy(key), copy(item)] }
      when Array then value.map { |item| copy(item) }
      when String then value.dup
      else value
      end
    end
    private_class_method :copy

    def play(player, events, now_ms, purpose:)
      player[:playback_serial] += 1
      player[:playback] = {
        id: player[:playback_serial], purpose: purpose, requested_ms: now_ms,
        events: copy(events)
      }
    end
    private_class_method :play

    def finish_player(state, seat, score, reason, now_ms, details = {})
      player = players(state).fetch(seat)
      player[:phase] = :finished
      player[:deadline_ms] = player[:playback] = nil
      state[:scores][seat] = score
      state[:results][seat] = {score: score, reason: reason, finished_ms: now_ms}.merge(details)
      state[:finished] = players(state).values.all? { |other| other[:phase] == :finished }
    end
    private_class_method :finish_player

    def speed_result(state, seat, start_ms, now_ms)
      elapsed = now_ms - start_ms
      finish_player(state, seat, (elapsed + 50) / 100, :correct, now_ms, elapsed_ms: elapsed)
    end
    private_class_method :speed_result

    def acknowledge_playback(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      playback = player[:playback]
      return false unless playback && action[:playback_id] == playback[:id]

      if action.key?(:onsets_ms)
        onsets = action[:onsets_ms]
        return false unless onsets.is_a?(Array) && onsets.length == playback[:events].length &&
          onsets.all? { |time| time.is_a?(Integer) && time.between?(playback[:requested_ms], now_ms) } &&
          onsets.each_cons(2).all? { |first, second| first <= second }
      end

      if action[:kind] == :playback_started
        return false unless state[:type] == "hit_duck" && player[:phase] == :listening

        player[:phase] = :responding
        player[:deadline_ms] = now_ms + 3_000
        return true
      end
      return false if state[:type] == "hit_duck" && player[:phase] == :listening

      player[:playback] = nil
      case state[:type]
      when "count_ducks"
        if player[:phase] == :listening
          player[:phase] = :responding
          player[:response_started_ms] = now_ms
          player[:deadline_ms] = now_ms + 20_000
        end
      when "rhythm"
        # Compare with what this player actually heard if the presenter's UI
        # schedule was delayed. Bot/model-only playback remains nominal.
        player[:rhythm_onsets] = onsets&.dup
        if player[:phase] == :listening
          player[:phase] = :ready
          player[:deadline_ms] = now_ms + 15_000
        end
      when "simon"
        player[:phase] = :responding
        player[:deadline_ms] = now_ms + 5_000
      end
      true
    end
    private_class_method :acknowledge_playback

    def start_count(state, random, now_ms)
      count = random.rand(5..15)
      interval = random.rand(400..900)
      events = Array.new(count) do |index|
        {sound: :quack, offset_ms: index * interval, duration_ms: 400}
      end
      state[:private][:count] = count
      state[:private][:events] = events
      players(state).each_value do |player|
        player[:phase], player[:attempts] = :listening, 0
        play(player, events, now_ms, purpose: :count)
      end
    end
    private_class_method :start_count

    def submit_count(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      return false unless player[:phase] == :responding

      case action[:kind]
      when :replay
        return false if player[:playback]

        play(player, state[:private][:events], now_ms, purpose: :count_replay)
      when :answer
        return false unless action[:value].is_a?(Integer) && action[:value] >= 0

        player[:attempts] += 1
        if action[:value] == state[:private][:count]
          speed_result(state, seat, player[:response_started_ms], now_ms)
        elsif player[:attempts] == 2
          finish_player(state, seat, nil, :attempts, now_ms)
        end
      else return false
      end
      true
    end
    private_class_method :submit_count

    def start_rhythm(state, random, now_ms)
      offset = 0
      events = Array.new(random.rand(6..10)) do |index|
        offset += random.rand(5..18) * 50 unless index.zero?
        {sound: :rhythm, tone: random.rand(2).zero? ? "f" : "j", offset_ms: offset, duration_ms: 90}
      end
      state[:private][:events] = events
      players(state).each_value do |player|
        player[:phase], player[:replays_left], player[:presses] = :listening, 1, []
        play(player, events, now_ms, purpose: :rhythm)
      end
    end
    private_class_method :start_rhythm

    def submit_rhythm(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      case action[:kind]
      when :replay
        return false unless player[:phase] == :ready && player[:replays_left] == 1 && !player[:playback]

        player[:replays_left] = 0
        play(player, state[:private][:events], now_ms, purpose: :rhythm_replay)
      when :begin
        return false unless player[:phase] == :ready && !player[:playback]

        player[:phase], player[:deadline_ms] = :responding, now_ms + 3_000
      when :tone
        return false unless player[:phase] == :responding && ["f", "j"].include?(action[:value])

        player[:presses] << {tone: action[:value].dup.freeze, at_ms: now_ms}
        player[:deadline_ms] = now_ms + 3_000
        finish_rhythm(state, seat, :complete, now_ms) if player[:presses].length == state[:private][:events].length
      else return false
      end
      true
    end
    private_class_method :submit_rhythm

    def finish_rhythm(state, seat, reason, now_ms)
      expected = state[:private][:events]
      player = players(state).fetch(seat)
      actual = player[:presses]
      onsets = player[:rhythm_onsets]
      tones = actual.each_with_index.count { |press, index| press[:tone] == expected[index][:tone] }
      interval_units = actual.each_cons(2).with_index.sum do |(previous, current), index|
        target = onsets ? onsets[index + 1] - onsets[index] : expected[index + 1][:offset_ms] - expected[index][:offset_ms]
        error = ((current[:at_ms] - previous[:at_ms]) - target).abs
        error <= 80 ? 2 : (error <= 160 ? 1 : 0)
      end
      score = Rational(50 * tones, expected.length) + Rational(25 * interval_units, expected.length - 1)
      finish_player(state, seat, score, reason, now_ms, correct_tones: tones, interval_units: interval_units)
    end
    private_class_method :finish_rhythm

    def start_order(state, random, now_ms)
      arrangement = GameRoomRandom.shuffle((1..8).to_a, random: random)
      arrangement = arrangement.rotate if arrangement == (1..8).to_a
      state[:public] = {sound_serial: 0, sound_event: nil}
      players(state).each_value do |player|
        player[:arrangement], player[:deadline_ms] = arrangement.dup, now_ms + 45_000
      end
    end
    private_class_method :start_order

    def submit_order(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      first = action[:value]
      return false unless first.is_a?(Integer) && first.between?(1, 8)

      case action[:kind]
      when :preview
        play(player, [{sound: :pitch, tone: player[:arrangement][first - 1], offset_ms: 0, duration_ms: 200}], now_ms, purpose: :preview)
      when :swap
        second = action[:other]
        return false unless second.is_a?(Integer) && second.between?(1, 8) && first != second

        values = player[:arrangement]
        values[first - 1], values[second - 1] = values[second - 1], values[first - 1]
        state[:public][:sound_serial] += 1
        state[:public][:sound_event] = {id: state[:public][:sound_serial], sound: :pitch, seat: seat,
          tones: [first, second].sort.map { |position| values[position - 1] }}
        finish_order(state, seat, now_ms) if values == (1..8).to_a
      else return false
      end
      true
    end
    private_class_method :submit_order

    # The ordered history freezes every arrangement at the first solution.
    # Later inputs cannot improve a loser's position or replace the winner.
    def finish_order(state, winner, now_ms)
      players(state).each do |seat, player|
        misplaced = player[:arrangement].each_with_index.count { |tone, index| tone != index + 1 }
        finish_player(state, seat, nil, winner == seat ? :correct : :finished, now_ms,
          correct: winner == seat, misplaced: misplaced)
      end
    end
    private_class_method :finish_order

    def start_simon(state, now_ms)
      state[:private][:sequence] = []
      players(state).each_value do |player|
        player[:level], player[:completed_length] = 1, 0
        play_simon(state, player, now_ms)
      end
    end
    private_class_method :start_simon

    def play_simon(state, player, now_ms, delay_ms: 0)
      sequence = state[:private][:sequence]
      while sequence.length < player[:level]
        # Index-derived draws make the shared growing prefix independent of
        # which player completes a level first, without storing an RNG object.
        sequence << Random.new(state[:private][:seed] + sequence.length * 1_000_003).rand(1..5)
      end
      # Tempo follows this player's level, not the fastest participant or
      # the shared prefix length. Keep each melody evenly spaced.
      interval_ms = [500 - (player[:level] - 1) * 10, 300].max
      events = sequence.first(player[:level]).each_with_index.map do |tone, index|
        {sound: :simon, tone: tone, offset_ms: index * interval_ms, duration_ms: 250}
      end
      player[:phase], player[:deadline_ms], player[:input_index] = :listening, nil, 0
      # The existing audio scheduler treats requested_ms as the earliest onset.
      # Keep input closed and its five-second timer unset throughout the pause.
      play(player, events, now_ms + delay_ms, purpose: :simon)
    end
    private_class_method :play_simon

    def submit_simon(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      return false unless action[:kind] == :tone && player[:phase] == :responding &&
        action[:value].is_a?(Integer) && action[:value].between?(1, 5)

      if action[:value] != state[:private][:sequence][player[:input_index]]
        finish_player(state, seat, player[:completed_length], :mistake, now_ms)
      else
        player[:input_index] += 1
        player[:deadline_ms] = now_ms + 5_000
        if player[:input_index] == player[:level]
          player[:completed_length] = player[:level]
          player[:level] += 1
          play_simon(state, player, now_ms, delay_ms: 1_000)
        end
      end
      true
    end
    private_class_method :submit_simon

    def start_memory(state, random, now_ms)
      state[:private][:pairs] = GameRoomRandom.shuffle((1..5).to_a * 2, random: random)
      state[:public] = {
        turn: state[:seats][random.rand(2)], turn_started_ms: now_ms, turn_deadline_ms: now_ms + 15_000,
        deadline_ms: now_ms + 90_000, removed: [], revealed: [],
        pairs: state[:seats].to_h { |seat| [seat, 0] }, sound_serial: 0, sound_event: nil
      }
    end
    private_class_method :start_memory

    def submit_memory(state, seat, action, now_ms)
      public = state[:public]
      position = action[:value]
      return false unless action[:kind] == :reveal && seat == public[:turn] && now_ms >= public[:turn_started_ms] &&
        now_ms < public[:turn_deadline_ms] &&
        position.is_a?(Integer) && position.between?(0, 9) && !public[:removed].include?(position) &&
        public[:revealed].none? { |entry| entry[:position] == position }

      index = position.zero? ? 9 : position - 1
      tone = state[:private][:pairs][index]
      public[:revealed] << {position: position, tone: tone}
      public[:sound_serial] += 1
      public[:sound_event] = {id: public[:sound_serial], sound: :memory, tone: tone, position: position, seat: seat}
      if public[:revealed].length == 2
        public[:sound_event][:matched] = public[:revealed][0][:tone] == tone
        if public[:sound_event][:matched]
          public[:pairs][seat] += 1
          public[:removed].concat(public[:revealed].map { |entry| entry[:position] })
        end
        next_memory_turn(state, now_ms)
        finish_memory(state, :complete, now_ms) if public[:removed].length == 10
      end
      true
    end
    private_class_method :submit_memory

    def next_memory_turn(state, now_ms)
      public = state[:public]
      public[:revealed] = []
      public[:turn] = state[:seats].find { |seat| seat != public[:turn] }
      public[:turn_started_ms] = now_ms
      public[:turn_deadline_ms] = now_ms + 15_000
    end
    private_class_method :next_memory_turn

    def finish_memory(state, reason, now_ms)
      state[:public][:revealed] = []
      state[:public][:turn] = nil
      state[:public][:turn_deadline_ms] = nil
      state[:seats].each { |seat| finish_player(state, seat, state[:public][:pairs][seat], reason, now_ms) }
    end
    private_class_method :finish_memory

    def expire_memory(state, now_ms)
      public = state[:public]
      if now_ms >= public[:deadline_ms]
        finish_memory(state, :timeout, public[:deadline_ms])
      else
        return false if now_ms < public[:turn_deadline_ms]

        # Catch up from the scheduled boundary, not the late timer callback.
        # This preserves whose turn it is after several elapsed empty turns.
        next_memory_turn(state, public[:turn_deadline_ms]) while now_ms >= public[:turn_deadline_ms]
      end
      true
    end
    private_class_method :expire_memory

    def start_targets(state, random, now_ms)
      state[:private][:targets] = Array.new(5) { random.rand(1..9) }
      players(state).each_value do |player|
        player[:target_index], player[:target_scores] = 0, []
        play_target(state, player, now_ms)
      end
    end
    private_class_method :start_targets

    def play_target(state, player, now_ms)
      player[:phase], player[:deadline_ms] = :listening, nil
      position = state[:private][:targets][player[:target_index]]
      play(player, [{sound: :target, pan: Rational(position - 5, 4), offset_ms: 0, duration_ms: 200}], now_ms, purpose: :target)
    end
    private_class_method :play_target

    def submit_target(state, seat, action, now_ms)
      player = players(state).fetch(seat)
      return false unless action[:kind] == :target && player[:phase] == :responding &&
        action[:value].is_a?(Integer) && action[:value].between?(1, 9)

      distance = (action[:value] - state[:private][:targets][player[:target_index]]).abs
      score = [100 - 25 * distance, 0].max
      complete_target(state, seat, score, :answer, now_ms)
      true
    end
    private_class_method :submit_target

    def complete_target(state, seat, score, reason, now_ms)
      player = players(state).fetch(seat)
      player[:target_scores] << score
      player[:target_index] += 1
      if player[:target_index] == 5
        finish_player(state, seat, Rational(player[:target_scores].sum, 5), :complete, now_ms,
          target_scores: player[:target_scores].dup, last_target_reason: reason)
      else
        play_target(state, player, now_ms)
      end
    end
    private_class_method :complete_target
  end
end
