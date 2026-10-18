# frozen_string_literal: true
require_relative 'tiles'
require_relative 'claim_window'

module GameRoomMahjong
  # Immutable tile ownership and turn transitions. The rules adapter supplies
  # already dealt hands and the live wall, excluding its reserved/replacement
  # tiles. This primitive deliberately does not choose a variant's wall policy,
  # certify winning claims, or expose a wall/other hands to the presentation.
  class TileFlow
    attr_reader :hands, :wall, :discards, :seat, :phase, :generation, :melds, :reserve, :last_draw, :draw_origin, :discard_history, :flowers, :replacement_source, :replacement_draws

    def initialize(hands:, wall:, seat:, discards: [], phase: :draw, generation: 0, melds: nil, reserve: [],
        last_draw: nil, draw_origin: nil, discard_history: nil, flowers: nil, replacement_source: :reserve, replacement_draws: 0)
      melds ||= Array.new(hands.is_a?(Array) ? hands.length : 0) { [] }
      flowers ||= Array.new(hands.is_a?(Array) ? hands.length : 0) { [] }
      unless hands.is_a?(Array) && [3, 4].include?(hands.length) && hands.all? { |hand| hand.is_a?(Array) } &&
          wall.is_a?(Array) && reserve.is_a?(Array) && discards.is_a?(Array) && seat.is_a?(Integer) && seat.between?(0, hands.length - 1) &&
          %i[draw discard reactions kong_reactions replacement exhausted].include?(phase) && generation.is_a?(Integer) && generation >= 0 &&
          melds.is_a?(Array) && melds.length == hands.length && %i[reserve wall_back riichi].include?(replacement_source) &&
          flowers.is_a?(Array) && flowers.length == hands.length && flowers.all? { |tiles| tiles.is_a?(Array) && tiles.all? { |tile| tile.is_a?(Integer) && tile.between?(136, 143) } }
        raise ArgumentError, 'Invalid mahjong tile flow'
      end
      unless discards.all? { |entry| entry.is_a?(Array) && entry.length == 2 && entry[0].is_a?(Integer) && entry[0].between?(0, hands.length - 1) }
        raise ArgumentError, 'Invalid mahjong discard history'
      end
      unless melds.each_with_index.all? { |sets, owner| valid_melds?(sets, owner, hands.length) }
        raise ArgumentError, 'Invalid exposed mahjong sets'
      end
      ordinary = hands.flatten + discards.map(&:last) + melds.flatten(1).flat_map { |meld| meld[:tiles] }
      tiles = ordinary + wall + reserve + flowers.flatten
      unless ordinary.all? { |tile| tile.is_a?(Integer) && tile.between?(0, 135) } &&
          tiles.all? { |tile| tile.is_a?(Integer) && tile.between?(0, 143) } && tiles.uniq.length == tiles.length
        raise ArgumentError, 'Duplicate or unsupported mahjong tile'
      end
      unless hands.each_with_index.all? { |hand, index| hand.length == (%i[discard kong_reactions].include?(phase) && index == seat ? 14 : 13) - 3 * melds[index].length }
        raise ArgumentError, 'Invalid concealed hand size'
      end
      raise ArgumentError, 'Missing latest discard' if phase == :reactions && (discards.empty? || discards.last.first != seat)
      raise ArgumentError, 'Nonempty exhausted wall' if phase == :exhausted && !wall.empty?
      unless replacement_draws.is_a?(Integer) && replacement_draws.between?(0, 4)
        raise ArgumentError, 'Invalid replacement draw count'
      end
      if replacement_source == :riichi && (reserve.length != 14 || tiles.any? { |tile| Tiles.bonus?(tile) })
        raise ArgumentError, 'Invalid Riichi dead wall'
      end
      if !last_draw.nil? && (phase != :discard || !hands[seat].include?(last_draw) || !%i[normal replacement flower_replacement].include?(draw_origin)) || last_draw.nil? && !draw_origin.nil?
        raise ArgumentError, 'Invalid last mahjong draw'
      end
      discard_history ||= discards
      unless discard_history.is_a?(Array) && discard_history.all? { |entry| entry.is_a?(Array) && entry.length == 2 && entry.first.is_a?(Integer) && entry.first.between?(0, hands.length - 1) && entry.last.is_a?(Integer) && entry.last.between?(0, 135) } &&
          discard_history.map(&:last).uniq.length == discard_history.length && (discards - discard_history).empty?
        raise ArgumentError, 'Invalid mahjong historical discards'
      end
      @hands = hands.map { |hand| hand.dup.freeze }.freeze
      @wall = wall.dup.freeze
      @discards = discards.map { |entry| entry.dup.freeze }.freeze
      @reserve = reserve.dup.freeze
      @flowers = flowers.map { |tiles| tiles.dup.freeze }.freeze
      @replacement_source = replacement_source
      @replacement_draws = replacement_draws
      @last_draw, @draw_origin = last_draw, draw_origin
      @discard_history = discard_history.map { |entry| entry.dup.freeze }.freeze
      @melds = melds.map { |sets| sets.map { |meld| meld.merge(tiles: meld[:tiles].dup.freeze).freeze }.freeze }.freeze
      @seat, @phase, @generation = seat, phase, generation
      freeze
    end

    def draw(seat:, generation:)
      require_turn!(seat, generation, :draw)
      return copy(phase: :exhausted, generation: @generation + 1) if wall.empty?
      live, replacement, bonuses = wall.dup, reserve.dup, flowers.map(&:dup)
      tile = live.shift
      flower_draw = Tiles.bonus?(tile)
      while Tiles.bonus?(tile)
        bonuses[seat] << tile
        source = replacement_source == :wall_back ? live : replacement
        if source.empty?
          return copy(wall: live, reserve: replacement, flowers: bonuses, phase: :exhausted, generation: @generation + 1) if live.empty?
          raise ArgumentError, 'No flower replacement tile'
        end
        tile = replacement_source == :wall_back ? source.pop : source.shift
      end
      next_hands = hands.map(&:dup)
      next_hands[seat] << tile
      copy(hands: next_hands, wall: live, reserve: replacement, flowers: bonuses, phase: :discard,
        generation: @generation + 1, last_draw: tile, draw_origin: flower_draw ? :flower_replacement : :normal)
    end

    def discard(seat:, tile:, generation:)
      require_turn!(seat, generation, :discard)
      raise ArgumentError, 'The seat does not own this tile' unless hands[seat].include?(tile)
      next_hands = hands.map(&:dup)
      next_hands[seat].delete(tile)
      copy(hands: next_hands, discards: discards + [[seat, tile]], discard_history: discard_history + [[seat, tile]],
        phase: :reactions, generation: @generation + 1, last_draw: nil, draw_origin: nil)
    end

    def after_passes(window)
      unless matching_window?(window) && window.resolution&.type == :passed
        raise ArgumentError, 'The current discard still requires claim resolution'
      end
      copy(seat: (seat + 1) % hands.length, phase: :draw, generation: generation + 1)
    end

    def apply_claim(window)
      raise ArgumentError, 'Unresolved or stale mahjong claims' unless matching_window?(window) && window.resolution
      choice = window.resolution
      return after_passes(window) if choice.type == :passed
      raise ArgumentError, 'Winning claims require score settlement' unless %i[chow pung kong].include?(choice.type)
      claimant = choice.seat
      discarded = discards.last.last
      needed = Hand.tiles_for([choice.type, choice.first_kind]).dup
      index = needed.index(Tiles.kind(discarded))
      raise ArgumentError, 'Claim does not contain the discard' unless index
      needed.delete_at(index)
      next_hands = hands.map(&:dup)
      taken = needed.map do |kind|
        physical = next_hands[claimant].find { |tile| Tiles.kind(tile) == kind }
        raise ArgumentError, 'Missing owned tiles for claim' unless physical
        next_hands[claimant].delete(physical)
        physical
      end
      raise ArgumentError, 'No kong replacement is available' if choice.type == :kong && !replacement_available?
      next_melds = melds.map(&:dup)
      next_melds[claimant] << {type: choice.type, first_kind: choice.first_kind, tiles: taken + [discarded], from: seat}
      copy(hands: next_hands, melds: next_melds, discards: discards[0...-1], seat: claimant,
        phase: choice.type == :kong ? :replacement : :discard, generation: generation + 1)
    end

    def draw_replacement(seat:, generation:)
      require_turn!(seat, generation, :replacement)
      raise ArgumentError, 'No replacement tile' unless replacement_available?
      source = (replacement_source == :wall_back ? wall : reserve).dup
      bonuses = flowers.map(&:dup)
      tile = nil
      until source.empty?
        tile = replacement_source == :wall_back ? source.pop : source.shift
        break unless Tiles.bonus?(tile)
        bonuses[seat] << tile
        tile = nil
      end
      changes = {replacement_source == :wall_back ? :wall : :reserve => source, flowers: bonuses}
      if replacement_source == :riichi
        live = wall.dup
        source << live.pop
        changes.merge!(wall: live, replacement_draws: replacement_draws + 1)
      end
      unless tile
        return copy(**changes, phase: :exhausted, generation: @generation + 1) if replacement_source == :wall_back || wall.empty?
        raise ArgumentError, 'No ordinary replacement tile'
      end
      next_hands = hands.map(&:dup)
      next_hands[seat] << tile
      copy(**changes, hands: next_hands, phase: :discard, generation: @generation + 1,
        last_draw: tile, draw_origin: bonuses[seat].length > flowers[seat].length ? :flower_replacement : :replacement)
    end

    def concealed_kong(seat:, kind:, generation:)
      require_turn!(seat, generation, :discard)
      Tiles.validate_kind(kind, bonuses: false)
      unless last_draw && replacement_available? && hands[seat].count { |tile| Tiles.kind(tile) == kind } == 4
        raise ArgumentError, 'No legal concealed kong'
      end
      next_hands = hands.map(&:dup)
      tiles = next_hands[seat].select { |tile| Tiles.kind(tile) == kind }
      next_hands[seat] -= tiles
      next_melds = melds.map(&:dup)
      next_melds[seat] << {type: :kong, first_kind: kind, tiles: tiles, from: nil}
      copy(hands: next_hands, melds: next_melds, phase: :replacement, generation: @generation + 1,
        last_draw: nil, draw_origin: nil)
    end

    def replacement_available?
      return !wall.empty? && replacement_draws < 4 if replacement_source == :riichi
      !(replacement_source == :wall_back ? wall : reserve).empty?
    end

    def begin_added_kong(seat:, kind:, generation:)
      require_turn!(seat, generation, :discard)
      Tiles.validate_kind(kind, bonuses: false)
      unless last_draw && replacement_available? && hands[seat].any? { |tile| Tiles.kind(tile) == kind } &&
          melds[seat].any? { |meld| meld[:type] == :pung && meld[:first_kind] == kind }
        raise ArgumentError, 'No legal added kong'
      end
      copy(phase: :kong_reactions, generation: @generation + 1, last_draw: nil, draw_origin: nil)
    end

    def complete_added_kong(kind:, generation:)
      require_turn!(seat, generation, :kong_reactions)
      tile = hands[seat].find { |physical| Tiles.kind(physical) == kind }
      index = melds[seat].index { |meld| meld[:type] == :pung && meld[:first_kind] == kind }
      raise ArgumentError, 'Invalid pending added kong' unless tile && index && replacement_available?
      next_hands = hands.map(&:dup)
      next_hands[seat].delete(tile)
      next_melds = melds.map(&:dup)
      original = next_melds[seat][index]
      next_melds[seat][index] = original.merge(type: :kong, tiles: original[:tiles] + [tile])
      copy(hands: next_hands, melds: next_melds, phase: :replacement, generation: @generation + 1)
    end

    # Settlement projection: the proposed fourth tile leaves its owner's hand
    # only when another seat wins. The exposed pung is never changed to a kong.
    def robbed_added_kong(kind:)
      raise ArgumentError, 'No pending added kong' unless phase == :kong_reactions
      tile = hands[seat].find { |physical| Tiles.kind(physical) == kind }
      unless tile && melds[seat].any? { |meld| meld[:type] == :pung && meld[:first_kind] == kind }
        raise ArgumentError, 'Invalid robbed kong tile'
      end
      next_hands = hands.map(&:dup)
      next_hands[seat].delete(tile)
      copy(hands: next_hands, phase: :reactions, discards: discards + [[seat, tile]],
        discard_history: discard_history + [[seat, tile]], generation: generation + 1)
    end

    def dora_indicators(ura: false)
      return [].freeze unless replacement_source == :riichi
      start = (ura ? 9 : 4) - replacement_draws
      reserve.slice(start, replacement_draws + 1).freeze
    end

    # A spectator receives counts and public discards only. A bot or player gets
    # exactly its own concealed tiles. Neither receives the future wall.
    def observation(viewer: nil)
      unless viewer.nil? || (viewer.is_a?(Integer) && viewer.between?(0, hands.length - 1))
        raise ArgumentError, 'Invalid mahjong observer'
      end
      {seat: seat, phase: phase, generation: generation, wall_count: wall.length,
       hand_counts: hands.map(&:length).freeze, concealed: viewer.nil? ? [].freeze : hands[viewer],
       discards: discards, melds: melds, discard_history: discard_history, flowers: flowers,
       dora_indicators: dora_indicators}.freeze
    end

    private

    def valid_melds?(sets, owner, seats)
      sets.is_a?(Array) && sets.length <= 4 && sets.all? do |meld|
        next false unless meld.is_a?(Hash) && meld.keys.sort == %i[first_kind from tiles type] &&
          %i[chow pung kong].include?(meld[:type]) && meld[:first_kind].is_a?(Integer) &&
          (meld[:from].nil? && meld[:type] == :kong || meld[:from].is_a?(Integer) && meld[:from].between?(0, seats - 1) && meld[:from] != owner) &&
          meld[:tiles].is_a?(Array) && meld[:tiles].all? { |tile| tile.is_a?(Integer) && tile.between?(0, 135) }
        next false if meld[:type] == :chow && (seats != 4 || owner != (meld[:from] + 1) % seats)
        meld[:tiles].map { |tile| Tiles.kind(tile) }.sort == Hand.tiles_for([meld[:type], meld[:first_kind]]).sort
      end
    rescue ArgumentError
      false
    end

    def matching_window?(window)
      phase == :reactions && window.is_a?(ClaimWindow) && window.seats == hands.length &&
        window.discarder == seat && window.tile_kind == Tiles.kind(discards.last.last) && window.generation == generation
    end

    def require_turn!(actor, token, expected)
      unless actor.is_a?(Integer) && actor == seat && token.is_a?(Integer) && token == generation && phase == expected
        raise ArgumentError, 'Stale or out-of-turn mahjong action'
      end
    end

    def copy(**changes)
      self.class.new(**{hands: hands, wall: wall, discards: discards, seat: seat, phase: phase,
        generation: generation, melds: melds, reserve: reserve, last_draw: last_draw,
        draw_origin: draw_origin, discard_history: discard_history, flowers: flowers,
        replacement_source: replacement_source, replacement_draws: replacement_draws}.merge(changes))
    end
  end
end
