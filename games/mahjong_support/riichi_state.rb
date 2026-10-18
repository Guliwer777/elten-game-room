# frozen_string_literal: true
require_relative 'tile_flow'

module GameRoomMahjong
  # Accepted-history riichi facts and deposit ledger. No input payload can
  # supply han, ippatsu or furiten. Declaration acceptance belongs after the
  # declaration discard's claim window (a ron on that discard voids riichi).
  class RiichiState
    Outcome = Struct.new(:points, :sticks, :delta, keyword_init: true)
    attr_reader :points, :starting_points, :levels, :ippatsu, :furiten, :waits, :sticks

    def initialize(points:, starting_points: points, levels: nil, ippatsu: nil, furiten: nil, waits: nil, sticks: 0)
      unless points.is_a?(Array) && [3, 4].include?(points.length) && points.all? { |value| value.is_a?(Integer) } &&
          starting_points.is_a?(Array) && starting_points.length == points.length && starting_points.all? { |value| value.is_a?(Integer) } &&
          sticks.is_a?(Integer) && sticks.between?(0, 1_000_000)
        raise ArgumentError, 'Invalid riichi deposit ledger'
      end
      size = points.length
      levels ||= Array.new(size, 0)
      ippatsu ||= Array.new(size, false)
      furiten ||= Array.new(size, false)
      waits ||= Array.new(size) { [] }
      unless levels.is_a?(Array) && levels.length == size && levels.all? { |value| value.is_a?(Integer) && [0, 1, 2].include?(value) } &&
          [ippatsu, furiten].all? { |flags| flags.is_a?(Array) && flags.length == size && flags.all? { |value| [true, false].include?(value) } } &&
          waits.is_a?(Array) && waits.length == size && waits.all? { |kinds| kinds.is_a?(Array) && kinds.uniq == kinds && kinds.all? { |kind| kind.is_a?(Integer) && kind.between?(0, 33) } }
        raise ArgumentError, 'Invalid accepted riichi facts'
      end
      unless size.times.all? { |seat| levels[seat].zero? ? !ippatsu[seat] && !furiten[seat] && waits[seat].empty? : !waits[seat].empty? }
        raise ArgumentError, 'Riichi facts require a declared ready hand'
      end
      @points, @starting_points, @levels = points.dup.freeze, starting_points.dup.freeze, levels.dup.freeze
      @ippatsu, @furiten = ippatsu.dup.freeze, furiten.dup.freeze
      @waits, @sticks = waits.map { |kinds| kinds.dup.freeze }.freeze, sticks
      freeze
    end

    # WRC 2025 declaration conditions: a player may declare on the last live
    # tile and below 1000 points; the deposit can make their balance negative.
    def declaration(flow:, seat:, tile:)
      check_seat!(seat)
      return nil unless flow.is_a?(TileFlow) && flow.hands.length == points.length && flow.seat == seat &&
        flow.phase == :discard && flow.last_draw && levels[seat].zero? && flow.hands[seat].include?(tile) &&
        flow.melds[seat].all? { |meld| meld[:from].nil? }
      hand = flow.hands[seat].dup
      hand.delete(tile)
      ready = Hand.waits(hand.map { |physical| Tiles.kind(physical) },
        melds: flow.melds[seat].map { |meld| [meld[:type], meld[:first_kind]] })
      return nil if ready.empty?
      uninterrupted_first = flow.discard_history.none? { |owner, _| owner == seat } && flow.melds.all?(&:empty?)
      {seat: seat, tile: tile, generation: flow.generation, level: uninterrupted_first ? 2 : 1, waits: ready.freeze}.freeze
    end

    def accept(declaration)
      unless declaration.is_a?(Hash) && declaration.keys.sort == %i[generation level seat tile waits] &&
          declaration[:seat].is_a?(Integer) && declaration[:seat].between?(0, points.length - 1) &&
          declaration[:level].is_a?(Integer) && [1, 2].include?(declaration[:level]) &&
          declaration[:tile].is_a?(Integer) && declaration[:tile].between?(0, 135) &&
          declaration[:generation].is_a?(Integer) && declaration[:generation] >= 0 &&
          declaration[:waits].is_a?(Array) && !declaration[:waits].empty?
        raise ArgumentError, 'Invalid accepted riichi declaration'
      end
      seat = declaration[:seat]
      raise ArgumentError, 'Riichi is already declared' unless levels[seat].zero?
      balances, next_levels, flags, ready = points.dup, levels.dup, ippatsu.dup, waits.dup
      balances[seat] -= 1000
      next_levels[seat], flags[seat], ready[seat] = declaration[:level], true, declaration[:waits]
      with(points: balances, levels: next_levels, ippatsu: flags, waits: ready, sticks: sticks + 1)
    end

    def concealed_kong_allowed?(flow:, seat:, kind:)
      check_seat!(seat)
      return true if levels[seat].zero?
      return false unless flow.is_a?(TileFlow) && flow.seat == seat && flow.phase == :discard && flow.last_draw &&
        Tiles.kind(flow.last_draw) == kind && flow.hands[seat].count { |tile| Tiles.kind(tile) == kind } == 4
      before = (flow.hands[seat] - [flow.last_draw]).map { |tile| Tiles.kind(tile) }
      melds = flow.melds[seat].map { |meld| [meld[:type], meld[:first_kind]] }
      structures = Hand.virtual_win_forms(before, melds: melds)
      return false if structures.empty? || structures.any? do |form|
        form.type != :standard || form.pair == kind || !form.groups.drop(melds.length).include?([:pung, kind]) ||
          form.groups.drop(melds.length).any? { |group| group != [:pung, kind] && Hand.tiles_for(group).include?(kind) }
      end
      after = before.dup
      3.times { after.delete_at(after.index(kind)) }
      Hand.waits(after, melds: melds + [[:kong, kind]]).sort == waits[seat].sort
    end

    def after_discard(seat:)
      check_seat!(seat)
      flags = ippatsu.dup
      flags[seat] = false
      with(ippatsu: flags)
    end

    def interrupt
      with(ippatsu: Array.new(points.length, false))
    end

    def pass_ron(seat:)
      check_seat!(seat)
      return self if levels[seat].zero?
      flags = furiten.dup
      flags[seat] = true
      with(furiten: flags)
    end

    def settle(payments:, winner: nil)
      unless payments.is_a?(Array) && payments.length == points.length && payments.all? { |value| value.is_a?(Integer) } && payments.sum.zero?
        raise ArgumentError, 'Invalid base riichi payments'
      end
      check_seat!(winner) unless winner.nil?
      final = points.each_with_index.map { |value, seat| value + payments[seat] }
      final[winner] += 1000 * sticks unless winner.nil?
      Outcome.new(points: final.freeze, sticks: winner.nil? ? sticks : 0,
        delta: final.each_with_index.map { |value, seat| value - starting_points[seat] }.freeze).freeze
    end

    private

    def check_seat!(seat)
      raise ArgumentError, 'Invalid riichi seat' unless seat.is_a?(Integer) && seat.between?(0, points.length - 1)
    end

    def with(**changes)
      self.class.new(**{points: points, starting_points: starting_points, levels: levels, ippatsu: ippatsu,
        furiten: furiten, waits: waits, sticks: sticks}.merge(changes))
    end
  end
end
