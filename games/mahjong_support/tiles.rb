# frozen_string_literal: true

module GameRoomMahjong
  # Physical identifiers remain stable throughout the event history. Tile kinds
  # 0..26 are the three numbered suits; 27..33 are winds and dragons.
  module Tiles
    SUITS = %i[characters dots bamboo].freeze
    WINDS = %i[east south west north].freeze
    DRAGONS = %i[white green red].freeze
    ORPHANS = [0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33].freeze
    module_function

    def kind(tile)
      raise ArgumentError, 'Invalid physical mahjong tile' unless tile.is_a?(Integer) && tile.between?(0, 143)
      tile < 136 ? tile / 4 : 34 + tile - 136
    end

    def suit(kind)
      validate_kind(kind)
      kind < 27 ? SUITS[kind / 9] : nil
    end

    def rank(kind)
      validate_kind(kind)
      kind < 27 ? kind % 9 + 1 : nil
    end

    def validate_kind(value, bonuses: true)
      maximum = bonuses ? 41 : 33
      raise ArgumentError, 'Invalid mahjong tile kind' unless value.is_a?(Integer) && value.between?(0, maximum)
      value
    end

    def bonus?(tile)
      kind(tile) >= 34
    end

    def terminal_or_honor?(kind)
      validate_kind(kind, bonuses: false)
      kind >= 27 || [0, 8].include?(kind % 9)
    end

    def matching_key(tile)
      value = kind(tile)
      value >= 38 ? :seasons : value >= 34 ? :flowers : value
    end

    def match?(first, second)
      first != second && matching_key(first) == matching_key(second)
    end

    def set(bonuses: false, sanma: false)
      tiles = (0...(bonuses ? 144 : 136)).to_a
      tiles.reject! { |tile| kind(tile).between?(1, 7) } if sanma
      tiles
    end
  end
end
