# frozen_string_literal: true
require_relative 'tiles'

module GameRoomMahjong
  # A read-only subtotal of identifiable honours/bonuses, not a winning score.
  # Concealed triplets count only while retained as triplets. Complete-hand
  # patterns and their exclusions remain exclusively in the real scorers.
  module FanProgress
    Item = Struct.new(:type, :kind, :points, keyword_init: true)
    module_function

    def items(round, seat)
      observation = round.flow.observation(viewer: seat)
      held = observation.fetch(:concealed).map { |tile| Tiles.kind(tile) }.tally
      sets = observation.fetch(:melds).fetch(seat)
      pungs = sets.reject { |meld| meld[:type] == :chow }.map { |meld| meld[:first_kind] }
      pungs |= held.select { |_, count| count >= 3 }.keys
      wind = 27 + (seat - round.dealer) % round.flow.hands.length
      unit = round.variant == 'mcr' ? 2 : 1
      result = (pungs & [31, 32, 33]).map { |kind| Item.new(type: :dragon, kind: kind, points: unit) }
      result << Item.new(type: :seat_wind, kind: wind, points: unit) if pungs.include?(wind)
      result << Item.new(type: :round_wind, kind: round.round_wind, points: unit) if pungs.include?(round.round_wind)
      bonuses(round, seat, wind, result)
      result.each(&:freeze).freeze
    end

    def bonuses(round, seat, wind, result)
      flowers = round.flow.flowers.fetch(seat).map { |tile| Tiles.kind(tile) }
      if round.variant == 'hong_kong'
        [34, 38].each do |first|
          family = flowers.select { |kind| kind.between?(first, first + 3) }
          if family.length == 4
            result << Item.new(type: first == 34 ? :flower_set : :season_set, points: 2)
          elsif family.include?(first + wind - 27)
            result << Item.new(type: :own_bonus, kind: first + wind - 27, points: 1)
          end
        end
      elsif round.variant == 'mcr'
        flowers.each { |kind| result << Item.new(type: :extra_flower, kind: kind, points: 1) }
      elsif (ledger = round.riichi_state) && ledger.levels.fetch(seat).positive?
        result << Item.new(type: :riichi, points: ledger.levels.fetch(seat))
      end
    end
  end
end
