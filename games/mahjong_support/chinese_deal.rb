# frozen_string_literal: true
require_relative 'tile_flow'
require_relative '../../lib/game_random'

module GameRoomMahjong
  module ChineseDeal
    module_function

    # Shared 144-tile policy: normal draws use the front, flowers and kongs
    # consume the back. This does not implement a reserved-dead-wall preset.
    def from_wall(wall, dealer: 0)
      unless wall.is_a?(Array) && wall.length == 144 && wall.sort == (0...144).to_a &&
          dealer.is_a?(Integer) && dealer.between?(0, 3)
        raise ArgumentError, 'Invalid Chinese mahjong initial wall'
      end
      live = wall.dup
      hands = Array.new(4) { [] }
      flowers = Array.new(4) { [] }
      order = 4.times.map { |offset| (dealer + offset) % 4 }
      3.times { order.each { |seat| hands[seat].concat(live.shift(4)) } }
      (order + [dealer]).each { |seat| hands[seat] << live.shift }
      order.each do |seat|
        hands[seat].map! do |physical|
          while Tiles.bonus?(physical)
            flowers[seat] << physical
            raise ArgumentError, 'Initial wall exhausted during flower replacement' if live.empty?
            physical = live.pop
          end
          physical
        end
      end
      TileFlow.new(hands: hands, flowers: flowers, wall: live, seat: dealer, phase: :discard,
        last_draw: hands[dealer].last, draw_origin: :normal, replacement_source: :wall_back)
    end

    def shuffled(seed:, dealer: 0)
      raise ArgumentError, 'Invalid mahjong deal seed' unless seed.is_a?(Integer) && seed.between?(0, (1 << 63) - 1)
      from_wall(GameRoomRandom.shuffle(Tiles.set(bonuses: true), random: Random.new(seed)), dealer: dealer)
    end
  end
end
