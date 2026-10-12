# frozen_string_literal: true

module GameRoomDuckRacing
  module Feathers
    START_PER_LAP = 6
    THAW_GRANT = 5
    MAX_FREEZE_TURNS = 4

    module_function

    def starting(laps)
      raise ArgumentError, "Invalid lap count" unless laps.is_a?(Integer) && laps.positive?

      START_PER_LAP * laps
    end

    def freeze_turns(progress:, last_progress:, board_length:)
      unless progress.is_a?(Integer) && last_progress.is_a?(Integer) && progress >= last_progress &&
          board_length.is_a?(Integer) && board_length.positive?
        raise ArgumentError, "Invalid freeze positions"
      end

      [1 + 3 * (progress - last_progress) / board_length, MAX_FREEZE_TURNS].min
    end

    # Supply only seats still in the race, including bots and frozen racers.
    # Run once after all transfers and penalties of an outcome have settled.
    def start_freezes!(racers, board_length:)
      return [] if racers.empty?

      last_progress = racers.values.map { |racer| racer.fetch(:progress) }.min
      newly_frozen = []
      racers.each do |seat, racer|
        next unless racer.fetch(:feathers).zero? && racer.fetch(:frozen_turns).zero?

        racer[:frozen_turns] = freeze_turns(progress: racer.fetch(:progress),
          last_progress: last_progress, board_length: board_length)
        newly_frozen << seat
      end
      newly_frozen
    end

    # This consumes an accepted skipped turn, not a UI update or another
    # player's move. The caller must deduplicate events before invoking it.
    def skip_frozen_turn!(racer)
      turns = racer.fetch(:frozen_turns)
      return nil if turns.zero?
      raise ArgumentError, "Invalid freeze duration" unless turns.is_a?(Integer) && turns.positive?

      racer[:frozen_turns] -= 1
      return :frozen unless racer[:frozen_turns].zero?

      racer[:feathers] += THAW_GRANT
      :thawed
    end
  end
end
