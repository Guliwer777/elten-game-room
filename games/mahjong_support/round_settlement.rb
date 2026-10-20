# frozen_string_literal: true
require_relative 'tile_flow'
require_relative 'riichi_scoring'
require_relative 'hong_kong_scoring'
require_relative 'payments'
require_relative 'riichi_deal'
require_relative 'mcr_scoring'

module GameRoomMahjong
  # Pure scorer bridge. The session reducer must supply accepted contextual
  # facts (riichi, dora, temporary furiten, winds), never fields from a win
  # request. The table/session facade remains unregistered during validation.
  module RoundSettlement
    Result = Struct.new(:winner, :discarder, :winning_tile, :score, :payments, :tenpai, keyword_init: true) do
      def draw?; winner.nil?; end
    end
    module_function

    def draw(flow:, variant:)
      unless flow.is_a?(TileFlow) && flow.phase == :exhausted && %w[riichi hong_kong mcr].include?(variant)
        raise ArgumentError, 'The mahjong wall is not exhausted'
      end
      shapes = variant == 'mcr' ? MCRShapes : Hand
      ready = flow.hands.each_with_index.map do |hand, seat|
        !shapes.waits(hand.map { |tile| Tiles.kind(tile) },
          melds: flow.melds[seat].map { |meld| [meld[:type], meld[:first_kind]] }).empty?
      end.freeze
      payments = variant == 'riichi' ? Payments.riichi_draw(tenpai: ready, seats: flow.hands.length) : Array.new(flow.hands.length, 0).freeze
      Result.new(payments: payments, tenpai: ready).freeze
    end

    def win(flow:, variant:, winner:, dealer:, round_wind: 27, riichi: 0, dora: 0,
        honba: 0, temporary_furiten: false, flowers: [], flags: {}, robbing_kong: false, include_ura: true)
      unless flow.is_a?(TileFlow) && %w[riichi hong_kong mcr].include?(variant) &&
          winner.is_a?(Integer) && winner.between?(0, flow.hands.length - 1) &&
          dealer.is_a?(Integer) && dealer.between?(0, flow.hands.length - 1) &&
          [true, false].include?(temporary_furiten) && [true, false].include?(robbing_kong) && [true, false].include?(include_ura) && flags.is_a?(Hash) &&
          (flags.keys - %i[ippatsu heavenly earthly]).empty? && flags.values.all? { |value| [true, false].include?(value) } &&
          riichi.is_a?(Integer) && riichi.between?(0, 2) && dora.is_a?(Integer) &&
          honba.is_a?(Integer) && honba.between?(0, 1000) && flowers.is_a?(Array)
        raise ArgumentError, 'Unsupported mahjong settlement context'
      end
      self_draw = flow.phase == :discard && flow.seat == winner && !flow.last_draw.nil?
      by_discard = flow.phase == :reactions && flow.seat != winner
      raise ArgumentError, 'No winning tile is currently available' unless self_draw || by_discard
      raise ArgumentError, 'A kong can only be robbed by another seat' if robbing_kong && !by_discard
      raise ArgumentError, 'The Chinese variants require four seats' if variant != 'riichi' && flow.hands.length != 4
      discarder = by_discard ? flow.seat : nil
      tile = self_draw ? flow.last_draw : flow.discards.last.last
      concealed = flow.hands[winner].map { |physical| Tiles.kind(physical) }
      concealed << Tiles.kind(tile) if by_discard
      melds = flow.melds[winner].map { |meld| [meld[:type], meld[:first_kind], !meld[:from].nil?] }
      seat_wind = 27 + (winner - dealer) % flow.hands.length
      derived_flags = flags.merge(replacement: self_draw && flow.draw_origin == :replacement,
        last_draw: self_draw && flow.draw_origin == :normal && flow.wall.empty?,
        last_discard: by_discard && flow.wall.empty? && !robbing_kong, robbing_kong: robbing_kong)
      if variant == 'riichi'
        raise ArgumentError, 'Dora must be derived from the accepted wall' unless dora == 0
        dora = RiichiDeal.dora_count(flow, winner: winner, include_ura: include_ura && riichi.positive?, claimed_tile: by_discard ? tile : nil)
        score = RiichiScoring.score(concealed: concealed, winning_tile: Tiles.kind(tile), melds: melds,
          self_draw: self_draw, seat_wind: seat_wind, round_wind: round_wind, riichi: riichi, dora: dora, flags: derived_flags)
        return nil unless score
        if by_discard
          waits = Hand.waits(flow.hands[winner].map { |physical| Tiles.kind(physical) }, melds: melds.map { |meld| meld.first(2) })
          discarded_kinds = flow.discard_history.select { |seat, _| seat == winner }.map { |_, physical| Tiles.kind(physical) }
          return nil if temporary_furiten || !(waits & discarded_kinds).empty?
        end
        payments = Payments.riichi(han: score.han, fu: score.fu, yakuman: score.yakuman,
          winner: winner, dealer: dealer, seats: flow.hands.length, discarder: discarder, honba: honba)
      elsif variant == 'hong_kong'
        raise ArgumentError, 'Riichi-only facts in Hong Kong settlement' unless riichi == 0 && dora == 0 && honba == 0 && flags.empty? && !temporary_furiten
        raise ArgumentError, 'Flower values must come from accepted tile ownership' unless flowers.empty?
        score = HongKongScoring.score(concealed: concealed, winning_tile: Tiles.kind(tile), melds: melds,
          self_draw: self_draw, seat_wind: seat_wind, round_wind: round_wind,
          flowers: flow.flowers[winner].map { |physical| Tiles.kind(physical) }, flags: derived_flags)
        return nil unless score
        payments = Payments.hong_kong(fan: score.fan, minimum: 3, winner: winner, discarder: discarder)
      else
        unless riichi == 0 && dora == 0 && honba == 0 && flags.empty? && !temporary_furiten && flowers.empty?
          raise ArgumentError, 'MCR scoring facts must come from accepted tile ownership'
        end
        visible = flow.discards.map(&:last) + flow.melds.flatten(1).flat_map { |meld| meld[:tiles] }
        visible -= [tile] if by_discard
        mcr_flags = {
          last_draw: self_draw && flow.wall.empty?, last_discard: by_discard && flow.wall.empty? && !robbing_kong,
          robbing_kong: robbing_kong,
          replacement: self_draw && flow.draw_origin == :replacement,
          last_kind: visible.count { |physical| Tiles.kind(physical) == Tiles.kind(tile) } == 3
        }
        score = MCRScoring.score(concealed: concealed, winning_tile: Tiles.kind(tile), melds: melds,
          self_draw: self_draw, seat_wind: seat_wind, round_wind: round_wind,
          flowers: flow.flowers[winner].length, flags: mcr_flags)
        return nil unless score
        payments = Payments.mcr(fan: score.fan, flowers: score.flowers, winner: winner, discarder: discarder)
      end
      Result.new(winner: winner, discarder: discarder, winning_tile: tile, score: score.freeze, payments: payments).freeze
    end
  end
end
