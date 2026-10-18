require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/solitaire'
include GameRoomTest::Assertions

position = GameRoomMahjong::Solitaire::Position
board = GameRoomMahjong::Solitaire.new(positions: [
  position.new(x: 0, y: 0, level: 0), position.new(x: 2, y: 0, level: 0),
  position.new(x: 4, y: 0, level: 0), position.new(x: 2, y: 0, level: 1)], tiles: [0, 1, 4, 5])
assert_equal([:left], board.open_sides(0))
assert_equal([:right], board.open_sides(2))
assert_equal([:left, :right], board.open_sides(3))
assert_equal(true, board.covered?(1))
assert_equal(false, board.free?(1))
assert_equal(true, board.free?(0))
flat = GameRoomMahjong::Solitaire.new(positions: [0, 1].flat_map { |row|
  [0, 1, 2].map { |column| position.new(x: column * 2, y: row * 2, level: 0) }
}, tiles: (0...6).to_a)
assert_equal([], flat.open_sides(1))
assert_equal(false, flat.covered?(1))
assert_equal(false, flat.free?(1))
puts 'PASS Solitaire side status: left/right/both, side-blocked versus covered and original free-tile rules'
