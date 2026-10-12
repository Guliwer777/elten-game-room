# frozen_string_literal: true

module GameRoomDuckRacing
  module Board
    LENGTH = 30
    Move = Data.define(:progress, :square, :lap, :finished)
    # Commands are data, not callbacks into UI or networking. The race engine
    # resolves them in this order and stores a continuation for challenges.
    SQUARES = {
      1 => [[:feathers, 1]], 2 => [[:feathers, 3]], 3 => [],
      4 => [[:cards, 1]], 5 => [[:feathers, 1], [:cards, 1]],
      6 => [[:feathers, 2]], 7 => [[:quiz]], 8 => [[:feathers, -1]],
      9 => [], 10 => [], 11 => [[:skip, 1]], 12 => [],
      13 => [[:cards, 1]], 14 => [[:skip, 2], [:feathers, 2]], 15 => [],
      16 => [[:random_move, 1, 8]], 17 => [], 18 => [[:skip, 2]],
      19 => [[:chance, 60, :feathers, 1], [:chance, 60, :cards, 1], [:chance, 60, :skip, 1]],
      20 => [[:quiz]], 21 => [[:skip, 1]], 22 => [[:cards, 1]],
      23 => [[:everyone_cards, 1]], 24 => [[:feathers, -2]],
      25 => [[:cards, 1]], 26 => [[:cards, 2], [:feathers, 2]],
      27 => [[:pass_hands]], 28 => [[:cards, 2], [:feathers, 2]],
      29 => [[:cards, 1]], 30 => [[:feathers, 1]]
    }.transform_values { |effects| effects.each(&:freeze).freeze }.freeze

    module_function

    def square(progress)
      raise ArgumentError, "Invalid race progress" unless progress.is_a?(Integer)

      progress % LENGTH + 1
    end

    def advance(progress, by:, laps:)
      unless laps.is_a?(Integer) && laps.positive? && progress.is_a?(Integer) &&
          progress.between?(0, LENGTH * laps - 1) && by.is_a?(Integer)
        raise ArgumentError, "Invalid race movement"
      end

      destination = [progress + by, 0].max
      Move.new(destination, square(destination), destination / LENGTH + 1,
        destination >= LENGTH * laps)
    end

    def landing(square, random:)
      effects = SQUARES.fetch(square)
      effects.filter_map do |effect|
        if effect.first == :chance
          effect.drop(2).freeze if random.rand(100) < effect[1]
        else
          effect
        end
      end.freeze
    end

    # Occupants are in arrival order, not seat order or previous-duel winners.
    # Remove a departure before registering its next arrival.
    def arrive!(occupants, seat, square)
      raise ArgumentError, "Invalid square" unless SQUARES.key?(square)

      leave!(occupants, seat)
      present = (occupants[square] ||= [])
      opponent = present.last
      present << seat
      opponent
    end

    def leave!(occupants, seat)
      occupants.each_value { |present| present.delete(seat) }
      occupants.delete_if { |_square, present| present.empty? }
    end
  end
end
