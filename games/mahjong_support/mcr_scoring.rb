# frozen_string_literal: true
require_relative 'mcr_policy'

module GameRoomMahjong
  # Pure end-to-end scoring pipeline used by the internal TableRound.
  # Catalog release still requires independent rule-profile validation.
  module MCRScoring
    Result = Struct.new(:fan, :flowers, :patterns, :form, :placement, :wait, keyword_init: true)
    module_function

    def score(concealed:, winning_tile:, melds: [], self_draw: false, seat_wind: 27,
        round_wind: 27, flowers: 0, flags: {})
      Tiles.validate_kind(winning_tile, bonuses: false)
      unless concealed.is_a?(Array) && concealed.include?(winning_tile) && melds.is_a?(Array) &&
          melds.all? { |meld| meld.is_a?(Array) && meld.length == 3 && [true, false].include?(meld[2]) && (meld[2] || meld[0] == :kong) } &&
          [true, false].include?(self_draw) && flowers.is_a?(Integer) && flowers.between?(0, 8) &&
          [seat_wind, round_wind].all? { |kind| kind.is_a?(Integer) && kind.between?(27, 30) } && flags.is_a?(Hash) &&
          (flags.keys - %i[last_draw last_discard replacement robbing_kong last_kind]).empty? && flags.values.all? { |value| [true, false].include?(value) }
        raise ArgumentError, 'Invalid MCR scoring context'
      end
      if flags[:last_draw] && !self_draw || flags[:last_discard] && self_draw ||
          flags[:replacement] && !self_draw || flags[:robbing_kong] && self_draw
        raise ArgumentError, 'Inconsistent MCR scoring context'
      end
      raw = melds.map { |meld| meld.first(2) }
      results = MCRShapes.forms(concealed, melds: raw).flat_map do |form|
        MCRShapes.winning_locations(form, winning_tile, melds.length, concealed: concealed).map do |placement, wait|
          facts = MCRPatterns.candidates(concealed: concealed, winning_tile: winning_tile,
            form: form, melds: melds, self_draw: self_draw, seat_wind: seat_wind,
            round_wind: round_wind, flowers: 0, flags: flags, placement: placement, wait: wait)
          selected = MCRPolicy.select(facts)
          if selected.empty?
            selected = [MCRPatterns::Candidate.new(id: 43, points: 8).freeze].freeze
          end
          Result.new(fan: selected.sum(&:points), flowers: flowers, patterns: selected,
            form: form, placement: placement, wait: wait).freeze
        end
      end
      best = results.max_by(&:fan)
      best && best.fan >= 8 ? best : nil
    end
  end
end
