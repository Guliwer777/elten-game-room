require_relative 'mahjong_tiles'
require_relative '../../games/mahjong_support/table_round'

module MahjongAddedKongFixture
  include MahjongTestTiles
  def added_kong_flow
    used = []
    take = lambda do |kind|
      tile = (kind * 4...kind * 4 + 4).find { |copy| !used.include?(copy) }
      raise 'Too many fixture copies' unless tile
      used << tile
      tile
    end
    pung = 3.times.map { take.call(2) }
    winner = mahjong_kinds('12m456789m11155z').map { |kind| take.call(kind) }
    fourth = take.call(2)
    rest = (0...136).to_a - used
    hands = [winner, rest.shift(10) + [fourth], rest.shift(13), rest.shift(13)]
    melds = [[], [{type: :pung, first_kind: 2, tiles: pung, from: 2}], [], []]
    GameRoomMahjong::TileFlow.new(hands: hands, melds: melds, wall: rest.drop(1),
      reserve: rest.first(1), seat: 1, phase: :discard, last_draw: fourth, draw_origin: :normal)
  end
end
