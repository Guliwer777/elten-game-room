require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../../games/mahjong_support/hong_kong_scoring'
require_relative '../../../games/mahjong_support/payments'
include GameRoomTest::Assertions
include MahjongTestTiles

def score(text, tile, **context)
  GameRoomMahjong::HongKongScoring.score(concealed: mahjong_kinds(text), winning_tile: mahjong_kinds(tile).first, **context)
end

assert_equal(nil, score('123456m23455p678s', '8s'), 'Four sets and a pair alone must not bypass the three-fan minimum')
result = score('123456m23455p678s', '8s', self_draw: true)
assert_equal(3, result.fan)
assert_equal({all_chows: 1, self_draw: 1, no_flowers: 1}, result.patterns)
assert_equal(nil, score('123456m23455p678s', '8s', self_draw: true, flowers: [35]), 'An irrelevant flower removes the no-flower point')
result = score('123456m23455p678s', '8s', self_draw: true, flowers: [34, 35, 36, 37])
assert_equal(4, result.fan, 'A complete flower set gives two fan, without also adding the seat flower')
result = score('123456789m11155z', '5z')
assert_equal(6, result.fan, 'Half flush, double-wind pung and no flowers')
result = score('222m555p666777s44p', '7s')
assert_equal(4, result.fan)
result = score('123m55566677z', '7z', melds: [[:chow, 9, true]])
assert_equal(6, result.fan, 'Little dragons include the dragon pung components')
result = score('19m19p19s12345677z', '7z')
assert_equal(13, result.fan)
assert_equal(1, result.patterns.length)
result = score('11122233344455z', '5z')
assert_equal(15, result.fan)
result = score('11123456789995m', '5m')
assert_equal(15, result.fan)
assert_raises(ArgumentError) { score('123456m23455p678s', '8s', flowers: [34, 34]) }
assert_raises(ArgumentError) { score('123456m23455p678s', '8s', flags: {robbing_kong: true}, self_draw: true) }
assert_equal([-48, 96, -24, -24], GameRoomMahjong::Payments.hong_kong(fan: 5, minimum: 3, winner: 1, discarder: 0))
assert_equal([-128, 384, -128, -128], GameRoomMahjong::Payments.hong_kong(fan: 15, minimum: 3, winner: 1))
puts 'PASS Hong Kong Clear Chapter fan, minimum, flowers, limit hands and capped half-pay settlement'
