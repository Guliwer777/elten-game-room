# frozen_string_literal: true

module GameRoomDuckRacing
  module Dice
    SIDES = [3, 6, 10, 12].freeze

    module_function

    def change!(racer, sides:, rolls:)
      unless SIDES.include?(sides) && rolls.is_a?(Integer) && rolls >= 0 &&
          (sides == 6 ? rolls.zero? : rolls.positive?)
        raise ArgumentError, "Invalid Duck Racing die modifier"
      end

      racer[:die_sides], racer[:die_rolls] = sides, rolls
    end

    def roll!(racer, random:, count: 1, race: false)
      unless count.is_a?(Integer) && count.between?(1, 2) && (!race || count == 1)
        raise ArgumentError, "Invalid Duck Racing dice count"
      end
      sides = racer.fetch(:die_sides)
      values = Array.new(count) { random.rand(sides) + 1 }
      if race && racer.fetch(:die_rolls).positive?
        racer[:die_rolls] -= 1
        racer[:die_sides] = 6 if racer[:die_rolls].zero?
      end
      values
    end
  end
end
