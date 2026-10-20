# frozen_string_literal: true
require_relative 'table_round'
require_relative '../../lib/private_card_ledger'

module GameRoomMahjong
  # Undrawn wall positions have no assigned value on any account. The native
  # pool samples each position when it is actually used, including replacement
  # tiles and indicators. This is a lazy uniformly shuffled wall, not a seed
  # from which a participant could reconstruct other hands or future draws.
  class PrivateTileFlow < TileFlow
    def initialize(incoming: nil, **fields)
      @incoming = incoming
      super(**fields)
    end

    def with(**changes); copy(**changes); end

    def receive(tile, bonuses: [], opening: false)
      copy(incoming: {tile: tile, bonuses: bonuses.dup.freeze, opening: opening}.freeze)
    end

    def dora_indicators(ura: false)
      super.select { |tile| tile.is_a?(Integer) }.freeze
    end

    def draw(seat:, generation:)
      return super if wall.empty?
      receive_draw(seat, generation, :draw)
    end

    def draw_replacement(seat:, generation:)
      receive_draw(seat, generation, :replacement)
    end

    private

    def physical_tile?(tile, bonuses:)
      super || GameRoomPrivateCardLedger.hidden?(tile) ||
        tile.is_a?(String) && tile.match?(/\Amahjong-wall:\d+\z/)
    end

    def tile_kind(tile); tile.is_a?(Integer) ? super : nil; end
    def bonus_tile?(tile); tile.is_a?(Integer) && super; end

    def receive_draw(actor, token, expected)
      require_turn!(actor, token, expected)
      raise ArgumentError, 'Missing authenticated Mahjong draw' unless @incoming
      tile, bonuses, opening = @incoming.values_at(:tile, :bonuses, :opening)
      unless (tile.nil? || physical_tile?(tile, bonuses: false)) && bonuses.is_a?(Array) &&
          bonuses.all? { |bonus| bonus.is_a?(Integer) && bonus.between?(136, 143) }
        raise ArgumentError, 'Invalid private Mahjong draw'
      end
      live, reserved = wall.dup, reserve.dup
      if expected == :replacement && replacement_source == :riichi
        raise ArgumentError, 'No replacement tile' unless replacement_available? && bonuses.empty?
        reserved.shift
        reserved << live.pop
      else
        count = bonuses.length + (tile.nil? ? 0 : 1)
        raise ArgumentError, 'No ordinary replacement tile' if live.length < count
        if expected == :draw
          live.shift
          (count - 1).times { live.pop }
        else
          count.times { live.pop }
        end
      end
      next_hands, next_flowers = hands.map(&:dup), flowers.map(&:dup)
      next_flowers[actor].concat(bonuses)
      if tile.nil?
        raise ArgumentError, 'Nonempty exhausted wall' unless live.empty?
        return copy(wall: live, reserve: reserved, flowers: next_flowers, phase: :exhausted,
          generation: self.generation + 1, incoming: nil, last_draw: nil, draw_origin: nil)
      end
      next_hands[actor] << tile
      copy(hands: next_hands, wall: live, reserve: reserved, flowers: next_flowers,
        phase: :discard, generation: self.generation + 1, incoming: nil, last_draw: tile,
        draw_origin: opening ? :normal : bonuses.any? ? :flower_replacement : expected == :draw ? :normal : :replacement,
        replacement_draws: replacement_draws + (expected == :replacement && replacement_source == :riichi ? 1 : 0))
    end

    def copy(**changes)
      super(**{incoming: @incoming}.merge(changes))
    end
  end

  # A foreign ready hand stays opaque until the end-of-hand audit. Never put
  # its wait list in public history just to reproduce the deposit ledger.
  class PrivateRiichiState < RiichiState
    def declaration(flow:, seat:, tile:)
      return super if flow.concealed_tiles(seat).length == flow.hands[seat].length
      return nil unless flow.seat == seat && flow.phase == :discard && flow.last_draw &&
        levels[seat].zero? && flow.hands[seat].include?(tile) && flow.melds[seat].all? { |meld| meld[:from].nil? }
      first = flow.discard_history.none? { |owner, _| owner == seat } && flow.melds.all?(&:empty?)
      {seat: seat, tile: tile, generation: flow.generation, level: first ? 2 : 1, waits: nil}.freeze
    end

    def concealed_kong_allowed?(flow:, seat:, kind:)
      return super unless waits[seat].nil?
      flow.last_draw.is_a?(Integer) && Tiles.kind(flow.last_draw) == kind
    end

    private

    def valid_waits?(kinds); kinds.nil? || super; end
  end

  class PrivateTableRound < TableRound
    def known_hand?(seat)
      flow.concealed_tiles(seat).length == flow.hands[seat].length
    end

    def winning_result(seat, include_ura: true)
      return nil unless known_hand?(seat)
      super
    end

    def legal_discards
      return [] if finished? || flow.phase != :discard
      return [flow.last_draw].select { |tile| tile.is_a?(Integer) } if riichi_state && riichi_state.levels[flow.seat].positive?
      flow.concealed_tiles(flow.seat).reject { |tile| blocked_discards.include?(Tiles.kind(tile)) }
    end

    def concealed_kongs
      return super if known_hand?(flow.seat)
      return [] if finished? || flow.phase != :discard || !flow.last_draw || !flow.replacement_available?
      kinds = flow.concealed_tiles(flow.seat).map { |tile| Tiles.kind(tile) }.tally.select { |_, count| count == 4 }.keys
      return kinds unless riichi_state && riichi_state.levels[flow.seat].positive?
      kinds.select { |kind| riichi_state.concealed_kong_allowed?(flow: flow, seat: flow.seat, kind: kind) }
    end

    def added_kongs
      return [] unless known_hand?(flow.seat)
      super
    end

    # Materialising a proved packet can add an option for that account. Keep
    # every already submitted response and its original discard generation.
    def refresh_claims
      return self unless window
      offers = if flow.phase == :kong_reactions
        window.offers.keys.to_h { |seat| [seat, winning_result(seat) ? [[:pass], [:win]] : [[:pass]]] }
      else
        ClaimOffers.for_discard(flow, replacement_available: flow.replacement_available?,
          sets_allowed: variant != 'riichi' || !flow.wall.empty?,
          win_checker: ->(seat, _hand, _tile) { !winning_result(seat).nil? }).offers
      end
      offers = offers.to_h do |seat, choices|
        choices = choices.select { |choice| %i[pass win].include?(choice.first) } if riichi_state && riichi_state.levels[seat].positive?
        choices = choices | [window.responses[seat]] if window.responses.key?(seat)
        [seat, choices]
      end
      with(window: ClaimWindow.new(seats: window.seats, discarder: window.discarder,
        tile_kind: window.tile_kind, generation: window.generation, offers: offers, responses: window.responses))
    end
  end
end
