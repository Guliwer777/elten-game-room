# frozen_string_literal: true

require_relative "board"
require_relative "cards"
require_relative "dice"
require_relative "feathers"
require_relative "settlement"
require_relative "challenges"
require_relative "race_effects"

module GameRoomDuckRacing
  # Pure reducer. Seats are stable positions, not controller usernames. The
  # application's event adapter authenticates controllers and records seeds.
  # This object owns no timer, sound, network request or background executor.
  class Race
    include RaceEffects

    def self.start(player_count:, laps:, seed:, enabled_challenges:)
      unless player_count.is_a?(Integer) && player_count.between?(2, 8) &&
          laps.is_a?(Integer) && laps.positive? && seed.is_a?(Integer) && seed >= 0
        raise ArgumentError, "Invalid Duck Racing setup"
      end
      Challenges.eligible(player_count: 2, enabled: enabled_challenges)
      if Challenges.eligible(player_count: player_count, enabled: enabled_challenges).empty?
        raise ArgumentError, "No challenge supports the race participants"
      end

      state = {
        phase: :turn, laps: laps, random: Random.new(seed), revision: 0,
        turn: 0, turn_number: 1, card_played: false, rolled: false,
        racers: {}, occupants: {1 => (0...player_count).to_a}, traps: {},
        enabled_challenges: enabled_challenges.uniq.freeze, next_card: 1,
        next_challenge: 1, challenge: nil, pending: [], continuation: nil,
        notices: [], winner: nil
      }
      player_count.times do |seat|
        state[:racers][seat] = {
          progress: 0, arrival: 0, feathers: Feathers.starting(laps),
          hand: [], hand_epoch: 0, die_sides: 6, die_rolls: 0,
          frozen_turns: 0, skip_turns: 0
        }
      end
      reducer = new(state)
      state[:racers].each_key { |seat| reducer.send(:draw_cards, seat, Cards::INITIAL_HAND_SIZE) }
      state[:notices] = []
      state
    end

    def initialize(state)
      @state = state
    end

    def apply(seat:, revision:, action:)
      return false unless @state[:phase] == :turn && seat.is_a?(Integer) && seat == @state[:turn] &&
        revision.is_a?(Integer) && revision == @state[:revision] && action.is_a?(Hash)

      racer = @state[:racers].fetch(seat)
      kind = action[:kind]
      if blocked?(racer)
        return false unless kind == :skip
      elsif kind == :play
        return false if @state[:card_played]
        card = racer[:hand].find { |copy| copy.id == action[:card] }
        return false unless card
        type = Cards::BY_ID.fetch(card.type)
        return false if racer[:feathers] < type.cost
        target = card_target(type, seat, action[:target])
        return false unless target
        return false if type.target == :square && @state[:traps].key?(Board.square(racer[:progress]))
        return false if type.id == "challenge" && @state[:racers].fetch(target)[:frozen_turns].positive?
      else
        return false unless kind == :roll
      end

      @state[:notices] = []
      @state[:revision] += 1
      case kind
      when :skip
        frozen = racer[:frozen_turns].positive?
        racer[:skip_turns] -= 1 if racer[:skip_turns].positive?
        thaw = Feathers.skip_frozen_turn!(racer)
        notice(:skipped, seat, frozen)
        notice(:thawed, seat, Feathers::THAW_GRANT) if thaw == :thawed
        next_turn
      when :roll
        sides = racer[:die_sides]
        value = Dice.roll!(racer, random: @state[:random], race: true).first
        @state[:rolled] = true
        @state[:continuation] = :next_turn
        notice(:rolled, seat, value)
        notice(:die_changed, seat, racer[:die_sides], 0) if sides != racer[:die_sides]
        move(seat, value)
        drain
      when :play
        racer[:hand].delete(card)
        racer[:feathers] += type.gain - type.cost
        @state[:card_played] = true
        @state[:continuation] = :turn
        notice(:played, seat, type.id, target)
        if type.target == :square
          square = Board.square(racer[:progress])
          @state[:traps][square] = {card: card, owner: seat}
          notice(:placed, seat, type.id, square)
        else
          queue_effects(target, seat, type.effects)
        end
        notice(:feathers, seat, type.gain) if type.gain.positive?
        drain
      end
      true
    end

    # Internal continuation used only after the challenge adapter validates
    # its inputs and computes Settlement::Result. Never accept balances from
    # a client packet as an ordinary race action.
    def complete_challenge(id:, result:)
      challenge = @state[:challenge]
      return false unless @state[:phase] == :challenge && challenge &&
        challenge[:id] == id && result.is_a?(Settlement::Result)
      seats = challenge[:participants]
      return false unless result.balances.keys.sort == seats.sort &&
        result.balances.values.all? { |value| value.is_a?(Integer) && value >= 0 }

      @state[:notices] = []
      @state[:revision] += 1
      result.balances.each { |seat, balance| @state[:racers].fetch(seat)[:feathers] = balance }
      notice(:challenge_result, id, result)
      # Settle the loss before destination effects can start another challenge
      # or award feathers. A zero balance freezes even if no transfer was paid.
      check_freezes
      @state[:challenge] = nil
      @state[:phase] = :turn
      drain
      true
    end

    # A confirmed participant change cancels only the unresolved challenge.
    # Already accepted card costs/movement stay accepted, and its pending
    # destination effects continue normally. A connection hiccup is not a
    # participant change; the outer adapter authenticates that distinction.
    def cancel_challenge(id:)
      return false unless @state[:phase] == :challenge && @state[:challenge]&.fetch(:id) == id

      @state[:notices] = [[:challenge_cancelled, id]]
      @state[:revision] += 1
      @state[:challenge] = nil
      @state[:phase] = :turn
      drain
      true
    end

    private

    def card_target(type, seat, supplied)
      return nil unless supplied.nil? || supplied.is_a?(Integer)
      return seat if [:self, :square].include?(type.target) && (supplied.nil? || supplied == seat)
      return nil unless supplied.is_a?(Integer) && @state[:racers].key?(supplied)
      return supplied if type.target == :any
      supplied if type.target == :opponent && supplied != seat
    end

    def blocked?(racer)
      racer[:skip_turns].positive? || racer[:frozen_turns].positive?
    end

    def notice(*parts)
      @state[:notices] << parts
    end

    def next_turn
      @state[:turn] = (@state[:turn] + 1) % @state[:racers].length
      @state[:turn_number] += 1
      @state[:card_played] = false
      @state[:rolled] = false
      @state[:continuation] = nil
    end

    def check_freezes
      Feathers.start_freezes!(@state[:racers], board_length: Board::LENGTH).each do |seat|
        notice(:frozen, seat, @state[:racers].fetch(seat)[:frozen_turns])
      end
    end

    def queue_effects(target, source, effects)
      @state[:pending].unshift(*effects.map { |effect| [:effect, target, source, effect] })
    end

    def move(seat, distance, effect: false)
      racer = @state[:racers].fetch(seat)
      movement = Board.advance(racer[:progress], by: distance, laps: @state[:laps])
      if movement.progress == racer[:progress]
        notice(:stayed, seat) if effect && distance.negative?
        return
      end

      travelled = movement.progress - racer[:progress]
      final_lap = !movement.finished && movement.lap == @state[:laps] &&
        racer[:progress] / Board::LENGTH + 1 < movement.lap
      racer[:progress] = movement.progress
      racer[:arrival] += 1
      notice(:moved, seat, movement, effect ? travelled : nil, final_lap)
      notice(:final_lap, seat) if final_lap
      if movement.finished
        @state[:phase] = :finished
        @state[:winner] = seat
        @state[:pending].clear
        @state[:continuation] = nil
        notice(:won, seat)
        return
      end

      Board.arrive!(@state[:occupants], seat, movement.square)
      stamp = racer[:arrival]
      @state[:pending].unshift([:square, seat, stamp], [:trap, seat, stamp], [:encounter, seat, stamp])
    end

    def drain
      while @state[:phase] == :turn && !@state[:pending].empty?
        task, seat, stamp_or_source, effect = @state[:pending].shift
        if task == :effect
          perform_effect(seat, stamp_or_source, effect)
          next
        end
        racer = @state[:racers].fetch(seat)
        # A square effect can move the duck again. Its former trap/encounter
        # must not fire after the duck has already left that arrival.
        next unless racer[:arrival] == stamp_or_source
        square = Board.square(racer[:progress])
        case task
        when :square
          queue_effects(seat, nil, Board.landing(square, random: @state[:random]))
        when :trap
          trap = @state[:traps][square]
          if trap
            effects = Cards::BY_ID.fetch(trap[:card].type).effects
            next if trap[:owner] == seat && effects.any? { |effect| effect.first == :steal_feathers }

            @state[:traps].delete(square)
            notice(:trap, seat, trap[:card].type, trap[:owner])
            queue_effects(seat, trap[:owner], effects)
          end
        when :encounter
          check_freezes
          next if racer[:frozen_turns].positive?
          opponent = @state[:occupants].fetch(square, []).reverse.find do |other|
            other != seat && @state[:racers].fetch(other)[:frozen_turns].zero?
          end
          start_challenge([opponent, seat], trigger: :encounter, initiator: seat) if opponent
        else
          raise ArgumentError, "Unknown race continuation"
        end
      end
      return unless @state[:phase] == :turn && @state[:pending].empty?

      check_freezes
      @state[:continuation] == :next_turn ? next_turn : @state[:continuation] = nil
    end

    def start_challenge(seats, trigger:, kind: nil, initiator: nil)
      participants = seats.compact.uniq
      unless kind == "quiz" && [:square_question, :question_card].include?(trigger)
        participants.reject! { |seat| @state[:racers].fetch(seat)[:frozen_turns].positive? }
      end
      return if participants.length < 2

      if kind.nil?
        available = Challenges.eligible(player_count: participants.length, enabled: @state[:enabled_challenges])
        raise ArgumentError, "No eligible challenge for participants" if available.empty?
        kind = available.fetch(@state[:random].rand(available.length)).id
      end
      snapshot = {board_length: Board::LENGTH, laps: @state[:laps], racers: @state[:racers].transform_values do |racer|
        {progress: racer[:progress], feathers: racer[:feathers], card_count: racer[:hand].length,
          die_sides: racer[:die_sides], die_rolls: racer[:die_rolls]}
      end}
      @state[:challenge] = {
        id: @state[:next_challenge], kind: kind, participants: participants,
        trigger: trigger, seed: @state[:random].rand(2**128), race_snapshot: snapshot
      }
      @state[:next_challenge] += 1
      @state[:phase] = :challenge
      notice(:challenge, @state[:challenge][:id], kind, participants.dup, initiator, trigger)
    end
  end
end
