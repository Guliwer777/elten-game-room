# frozen_string_literal: true
require_relative 'mcr_combination'

module GameRoomMahjong
  # Only the kong/concealed-pung component, not a complete hand score. Policy:
  # EMA MCR Rule Committee, Kong Scoring in MCR, September 2012. A kong fan
  # cannot stack with another kong fan; independent concealed-pung fan can.
  module MCRKongScoring
    KONG_IDS = [5, 17, 48, 57, 67, 74].freeze
    CONCEALED_PUNG_IDS = [12, 33, 66].freeze
    EXCLUSIONS = {
      5 => [17, 48, 57, 67, 74],
      17 => [48, 57, 67, 74],
      48 => [57, 66, 67, 74],
      57 => [67, 74],
      12 => [33, 66],
      33 => [66]
    }.transform_values(&:freeze).freeze
    module_function

    def components(candidates)
      raise ArgumentError, 'Invalid MCR kong candidate list' unless candidates.is_a?(Array) && candidates.all? { |entry| entry.is_a?(MCRPatterns::Candidate) }
      selected = candidates.select { |entry| (KONG_IDS + CONCEALED_PUNG_IDS).include?(entry.id) }
      MCRCombination.select(selected, exclusions: EXCLUSIONS)
    end
  end
end
