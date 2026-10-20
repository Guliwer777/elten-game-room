require_relative 'mahjong_tiles'
require_relative '../../games/mahjong_support/table_round'

module MahjongRoundFixture
  include MahjongTestTiles

  def ready_flow(text, winning, self_draw: false, own_discard: nil)
    counts = Hash.new(0)
    take = ->(kind) { physical = kind * 4 + counts[kind]; counts[kind] += 1; raise 'Too many copies' if counts[kind] > 4; physical }
    hand = mahjong_kinds(text).map { |kind| take.call(kind) }
    tile = take.call(mahjong_kinds(winning).first)
    historical = own_discard ? [[0, take.call(mahjong_kinds(own_discard).first)]] : []
    rest = GameRoomMahjong::Tiles.set - hand - [tile] - historical.map(&:last)
    hands = [hand] + 3.times.map { rest.shift(13) }
    if self_draw
      GameRoomMahjong::TileFlow.new(hands: hands, wall: [tile] + rest, seat: 0, discards: historical).draw(seat: 0, generation: 0)
    else
      hands[1] << tile
      GameRoomMahjong::TileFlow.new(hands: hands, wall: rest, seat: 1, phase: :discard, discards: historical).discard(seat: 1, tile: tile, generation: 0)
    end
  end
end
