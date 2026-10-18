# frozen_string_literal: true
require_relative 'tiles'
require_relative '../../lib/game_random'

module GameRoomMahjong
  class Solitaire
    Position = Struct.new(:x, :y, :level, keyword_init: true)
    Deal = Struct.new(:game, :solution, keyword_init: true)
    LAYOUTS = %w[flat terraces].freeze
    attr_reader :positions, :tiles, :remaining

    def self.layout(name)
      layers = case name
      when 'flat' then [[12, 12, 0, 0, 0]]
      when 'terraces' then [[12, 8, 0, 0, 0], [6, 6, 6, 2, 1], [4, 3, 8, 5, 2]]
      else raise ArgumentError, 'Unknown solitaire layout'
      end
      layers.flat_map do |width, height, left, top, level|
        Array.new(height) do |row|
          Array.new(width) { |column| Position.new(x: left + 2 * column, y: top + 2 * row, level: level).freeze }
        end.flatten
      end.freeze
    end

    # Assign pairs along a geometrically legal removal order. This proves that
    # a fresh puzzle can be solved, without claiming every later choice wins.
    def self.deal(seed:, layout: 'terraces')
      raise ArgumentError, 'Invalid solitaire seed' unless seed.is_a?(Integer) && seed.between?(0, (1 << 63) - 1)
      positions = self.layout(layout)
      random = Random.new(seed)
      pairs = (0...136).each_slice(2).to_a + [[136, 137], [138, 139], [140, 141], [142, 143]]
      pairs = GameRoomRandom.shuffle(pairs, random: random)
      geometry = new(positions: positions, tiles: (0...144).to_a)
      assigned = Array.new(144)
      solution = []
      until geometry.finished?
        highest = geometry.remaining.map { |slot| positions[slot].level }.max
        free = geometry.free_slots.select { |slot| positions[slot].level == highest }
        raise 'Solitaire layout has no complete removal order' if free.length < 2
        selected = GameRoomRandom.shuffle(free, random: random).first(2)
        pair = pairs.fetch(solution.length)
        selected.each_with_index { |slot, index| assigned[slot] = pair[index] }
        solution << selected.freeze
        geometry = new(positions: positions, tiles: geometry.tiles, remaining: geometry.remaining - selected)
      end
      Deal.new(game: new(positions: positions, tiles: assigned), solution: solution.freeze).freeze
    end

    def initialize(positions:, tiles:, remaining: nil)
      unless positions.is_a?(Array) && positions.length.between?(2, 144) && positions.length.even? &&
          positions.all? { |position| position.is_a?(Position) && [position.x, position.y, position.level].all? { |value| value.is_a?(Integer) && value.between?(0, 64) } }
        raise ArgumentError, 'Invalid solitaire positions'
      end
      coordinates = positions.map { |position| [position.x, position.y, position.level] }
      raise ArgumentError, 'Duplicate solitaire position' unless coordinates.uniq.length == positions.length
      if positions.each_with_index.any? { |left, index| positions.drop(index + 1).any? { |right| left.level == right.level && (left.x - right.x).abs < 2 && (left.y - right.y).abs < 2 } }
        raise ArgumentError, 'Overlapping tiles in the same layer'
      end
      raise ArgumentError, 'Invalid solitaire tile list' unless tiles.is_a?(Array) && tiles.length == positions.length && tiles.uniq.length == tiles.length
      tiles.each { |tile| Tiles.kind(tile) }
      remaining ||= positions.each_index.to_a
      unless remaining.is_a?(Array) && remaining.uniq.length == remaining.length && remaining.length.even? &&
          remaining.all? { |slot| slot.is_a?(Integer) && slot.between?(0, positions.length - 1) }
        raise ArgumentError, 'Invalid remaining solitaire slots'
      end
      @positions = positions.map { |position| position.dup.freeze }.freeze
      @tiles = tiles.dup.freeze
      @remaining = remaining.sort.freeze
      freeze
    end

    def free?(slot)
      return false unless slot.is_a?(Integer) && remaining.include?(slot)
      return false if covered?(slot)
      open_sides(slot).any?
    end

    def open_sides(slot)
      return [] unless slot.is_a?(Integer) && remaining.include?(slot)
      position = positions.fetch(slot)
      neighbors = remaining.filter_map do |other|
        side = positions.fetch(other)
        next unless side.level == position.level && (side.y - position.y).abs < 2
        side.x - position.x if (side.x - position.x).abs == 2
      end
      sides = []
      sides << :left unless neighbors.include?(-2)
      sides << :right unless neighbors.include?(2)
      sides.freeze
    end

    def covered?(slot)
      return false unless slot.is_a?(Integer) && remaining.include?(slot)
      position = positions.fetch(slot)
      remaining.any? do |other|
        above = positions.fetch(other)
        above.level > position.level && (above.x - position.x).abs < 2 && (above.y - position.y).abs < 2
      end
    end

    def free_slots
      remaining.select { |slot| free?(slot) }
    end

    def pairs
      free_slots.combination(2).select { |first, second| Tiles.match?(tiles[first], tiles[second]) }
    end

    def remove(first, second)
      unless first != second && free?(first) && free?(second) && Tiles.match?(tiles.fetch(first), tiles.fetch(second))
        raise ArgumentError, 'Only two free matching tiles can be removed'
      end
      self.class.new(positions: positions, tiles: tiles, remaining: remaining - [first, second])
    end

    def finished?
      remaining.empty?
    end

    def blocked?
      !finished? && pairs.empty?
    end
  end
end
