require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/hong_kong_deal'
include GameRoomTest::Assertions

12.times do |seed|
  4.times do |dealer|
    flow = GameRoomMahjong::HongKongDeal.shuffled(seed: seed, dealer: dealer)
    repeat = GameRoomMahjong::HongKongDeal.shuffled(seed: seed, dealer: dealer)
    assert_equal(flow.hands, repeat.hands)
    assert_equal(flow.wall, repeat.wall)
    assert_equal(flow.flowers, repeat.flowers)
    assert_equal(14, flow.hands[dealer].length)
    assert_equal([13, 13, 13], flow.hands.each_with_index.reject { |_, seat| seat == dealer }.map { |hand, _| hand.length })
    assert_equal((0...144).to_a, (flow.hands.flatten + flow.wall + flow.flowers.flatten).sort)
    assert(flow.hands.flatten.none? { |tile| GameRoomMahjong::Tiles.bonus?(tile) })
    assert_equal(:wall_back, flow.replacement_source)
    assert_equal([], flow.reserve)
    assert_equal([], flow.dora_indicators)
    assert_equal(dealer, flow.seat)
    assert_equal(:discard, flow.phase)
  end
end
wall = (0...144).to_a
snapshot = wall.dup
GameRoomMahjong::HongKongDeal.from_wall(wall)
assert_equal(snapshot, wall)
assert_raises(ArgumentError) { GameRoomMahjong::HongKongDeal.shuffled(seed: -1) }
assert_raises(ArgumentError) { GameRoomMahjong::HongKongDeal.from_wall((0...136).to_a) }
assert_raises(ArgumentError) { GameRoomMahjong::HongKongDeal.from_wall(wall, dealer: 4) }
puts 'PASS Hong Kong deal: 48 reproducible dealer/seed hands, 144 tiles conserved, exposed flowers, back-wall replacement preset and no reserved wall/dora'
