# frozen_string_literal: true
require_relative 'tile_flow'
require_relative '../../lib/game_random'

module GameRoomMahjong
  module RiichiDeal
    module_function

    # Our normalized dead wall stores R1..R4, five face-up indicators, then
    # five ura indicators. This is a deterministic representation, not a
    # display of the physical stacks. Consumed R tiles are replaced by the
    # last live-wall tile, preserving fourteen reserved physical tiles.
    def from_wall(wall, seats: 4, dealer: 0)
      unless [3, 4].include?(seats) && seats.is_a?(Integer) && dealer.is_a?(Integer) && dealer.between?(0, seats - 1) &&
          wall.is_a?(Array) && wall.sort == Tiles.set(sanma: seats == 3)
        raise ArgumentError, 'Invalid Riichi initial wall'
      end
      live = wall.dup
      reserve = live.pop(14)
      hands = Array.new(seats) { [] }
      order = seats.times.map { |offset| (dealer + offset) % seats }
      3.times { order.each { |seat| hands[seat].concat(live.shift(4)) } }
      (order + [dealer]).each { |seat| hands[seat] << live.shift }
      TileFlow.new(hands: hands, wall: live, reserve: reserve, replacement_source: :riichi,
        seat: dealer, phase: :discard, last_draw: hands[dealer].last, draw_origin: :normal)
    end

    def shuffled(seed:, seats: 4, dealer: 0)
      raise ArgumentError, 'Invalid Riichi deal seed' unless seed.is_a?(Integer) && seed.between?(0, (1 << 63) - 1)
      from_wall(GameRoomRandom.shuffle(Tiles.set(sanma: seats == 3), random: Random.new(seed)), seats: seats, dealer: dealer)
    end

    def dora_kind(indicator, sanma: false)
      kind = Tiles.kind(indicator)
      raise ArgumentError, 'Invalid dora indicator' if kind >= 34
      return kind == 0 ? 8 : 0 if sanma && [0, 8].include?(kind)
      return (kind / 9) * 9 + (kind + 1) % 9 if kind < 27
      return 27 + (kind - 27 + 1) % 4 if kind < 31
      31 + (kind - 31 + 1) % 3
    end

    def dora_count(flow, winner:, include_ura: false, claimed_tile: nil)
      raise ArgumentError, 'Invalid dora seat' unless winner.is_a?(Integer) && winner.between?(0, flow.hands.length - 1)
      indicators = flow.dora_indicators + (include_ura ? flow.dora_indicators(ura: true) : [])
      dora = indicators.map { |tile| dora_kind(tile, sanma: flow.hands.length == 3) }
      physical = flow.hands[winner] + flow.melds[winner].flat_map { |meld| meld[:tiles] }
      physical += [claimed_tile] unless claimed_tile.nil?
      physical.sum { |tile| dora.count(Tiles.kind(tile)) }
    end
  end
end
