# frozen_string_literal: true

module GameRoomDuckRacing
  module Challenges
    Type = Data.define(:id, :reference, :minimum_players, :maximum_players)
    TYPES = [
      ["rock_paper_scissors", 1, 2, 2], ["dice_duel", 2, 2, 8],
      ["blackjack", 3, 2, 8], ["risky_dice", 4, 2, 8],
      ["guess_number", 6, 2, 8], ["copy_number", 7, 2, 8],
      ["arithmetic", 8, 2, 8], ["race_question", 9, 2, 8],
      ["numbered_balls", 19, 2, 2], ["count_ducks", 22, 2, 8],
      ["rhythm", 24, 2, 8], ["sound_order", 25, 2, 8],
      ["simon", 26, 2, 8], ["sound_memory", 27, 2, 2],
      ["hit_duck", 28, 2, 8], ["quiz", nil, 2, 8],
      ["audio_ball", nil, 2, 2], ["axel_pong", nil, 2, 2]
    ].map { |fields| Type.new(*fields) }.freeze
    BY_ID = TYPES.to_h { |type| [type.id, type] }.freeze

    module_function

    # Enabled is mandatory: declaring a type does not make an unfinished
    # adapter selectable. Never drop players to fit a two-player challenge.
    def eligible(player_count:, enabled:)
      raise ArgumentError, "Invalid participant count" unless player_count.is_a?(Integer) && player_count.between?(2, 8)
      raise ArgumentError, "Invalid challenge selection" unless enabled.is_a?(Array) && enabled.all? { |id| BY_ID.key?(id) }

      TYPES.select do |type|
        enabled.include?(type.id) && player_count.between?(type.minimum_players, type.maximum_players)
      end.freeze
    end
  end
end
