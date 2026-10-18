require_relative '../../support/assertions'
require_relative '../../support/elten_array_shuffle'
require_relative '../../../games/mahjong_support/mcr_deal'
include GameRoomTest::Assertions

12.times do |seed|
  4.times do |dealer|
    flow = GameRoomMahjong::MCRDeal.shuffled(seed: seed, dealer: dealer)
    repeat = GameRoomMahjong::MCRDeal.shuffled(seed: seed, dealer: dealer)
    assert_equal(flow.hands, repeat.hands)
    assert_equal(flow.wall, repeat.wall)
    assert_equal(flow.flowers, repeat.flowers)
    assert_equal(14, flow.hands[dealer].length)
    assert_equal([13, 13, 13], flow.hands.each_with_index.reject { |_, seat| seat == dealer }.map { |hand, _| hand.length })
    assert(flow.hands.flatten.all? { |tile| tile < 136 })
    assert_equal((0...144).to_a, (flow.hands.flatten + flow.flowers.flatten + flow.wall).sort)
    assert_equal(:wall_back, flow.replacement_source)
  end
end

# A flower at the normal draw end is replaced from the back, repeatedly.
hands = 4.times.map { |seat| (seat * 13...(seat + 1) * 13).to_a }
flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: [136, 60, 61, 62, 137, 138], seat: 0, replacement_source: :wall_back)
drawn = flow.draw(seat: 0, generation: 0)
assert_equal([136, 138, 137], drawn.flowers[0])
assert_equal(62, drawn.last_draw)
assert_equal(:flower_replacement, drawn.draw_origin)
assert_equal([60, 61], drawn.wall)
assert_equal(14, drawn.hands[0].length)
assert_equal([], flow.flowers[0])
assert_equal(6, flow.wall.length)

terminal = GameRoomMahjong::TileFlow.new(hands: hands, wall: [136, 137], seat: 0, replacement_source: :wall_back).draw(seat: 0, generation: 0)
assert_equal(:exhausted, terminal.phase)
assert_equal([136, 137], terminal.flowers[0])
assert_equal(13, terminal.hands[0].length)
assert_equal(nil, terminal.last_draw)
kong_hands = [[16] + (80..92).to_a, [8, 12, 20, 24] + (40..48).to_a,
              [17, 18, 19] + (52..61).to_a, (64..76).to_a]
kong = GameRoomMahjong::TileFlow.new(hands: kong_hands, wall: [96, 97, 136], seat: 0,
  phase: :discard, replacement_source: :wall_back).discard(seat: 0, tile: 16, generation: 0)
window = GameRoomMahjong::ClaimWindow.new(seats: 4, discarder: 0, tile_kind: 4, generation: kong.generation,
  offers: {1=>[[:pass]], 2=>[[:kong, 4]], 3=>[[:pass]]},
  responses: {1=>[:pass], 2=>[:kong, 4], 3=>[:pass]})
declared = kong.apply_claim(window)
after_flower = declared.draw_replacement(seat: 2, generation: declared.generation)
assert_equal([136], after_flower.flowers[2])
assert_equal(97, after_flower.last_draw)
assert_equal(:flower_replacement, after_flower.draw_origin, 'A flower after kong must not award the direct kong-replacement fan')
assert_raises(ArgumentError) { GameRoomMahjong::MCRDeal.from_wall((0...144).to_a.fill(0, 0, 2)) }
assert_raises(ArgumentError) { GameRoomMahjong::MCRDeal.shuffled(seed: -1) }
puts 'PASS MCR deal: 48 reproducible dealer/seed layouts, 14/13 tile counts, 144 physical tiles conserved, repeated back-wall flower replacement and flower-only exhaustion'
