require_relative '../../support/assertions'
require_relative '../../support/elten_array_shuffle'
require_relative '../../../games/mahjong_support/riichi_deal'
require_relative '../../../games/mahjong_support/claim_offers'
include GameRoomTest::Assertions

[3, 4].each do |seats|
  8.times do |seed|
    seats.times do |dealer|
      flow = GameRoomMahjong::RiichiDeal.shuffled(seed: seed, seats: seats, dealer: dealer)
      repeated = GameRoomMahjong::RiichiDeal.shuffled(seed: seed, seats: seats, dealer: dealer)
      assert_equal(flow.hands, repeated.hands)
      assert_equal(flow.reserve, repeated.reserve)
      assert_equal(14, flow.reserve.length)
      assert_equal(14, flow.hands[dealer].length)
      assert_equal(seats == 3 ? 54 : 69, flow.wall.length)
      assert_equal(GameRoomMahjong::Tiles.set(sanma: seats == 3), (flow.hands.flatten + flow.wall + flow.reserve).sort)
      assert_equal([flow.reserve[4]], flow.dora_indicators)
      assert_equal([flow.reserve[9]], flow.dora_indicators(ura: true))
      assert(!flow.observation.key?(:reserve))
    end
  end
end

hands = [[16] + (80..92).to_a, [8, 12, 20, 24] + (40..48).to_a,
         [17, 18, 19] + (52..61).to_a, (64..76).to_a]
flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: [96, 97, 98], reserve: [100, 101, 102, 103, 14, 15, 104, 105, 106, 13, 107, 108, 109, 110],
  replacement_source: :riichi, seat: 0, phase: :discard)
discarded = flow.discard(seat: 0, tile: 16, generation: 0)
window = GameRoomMahjong::ClaimOffers.for_discard(discarded, replacement_available: true)
window.pending.each { |seat| window = window.respond(seat: seat, choice: seat == 2 ? [:kong, 4] : [:pass], generation: discarded.generation) }
claimed = discarded.apply_claim(window)
drawn = claimed.draw_replacement(seat: 2, generation: claimed.generation)
assert_equal(14, drawn.reserve.length)
assert_equal([96, 97], drawn.wall)
assert_equal(98, drawn.reserve.last)
assert_equal(100, drawn.last_draw)
assert_equal([14, 15], drawn.dora_indicators)
assert_equal([13, 107], drawn.dora_indicators(ura: true))
assert_equal(1, drawn.replacement_draws)
assert_equal(14, flow.reserve.length)
assert_equal(0, flow.replacement_draws)
assert_equal(0, GameRoomMahjong::RiichiDeal.dora_kind(32))
assert_equal(27, GameRoomMahjong::RiichiDeal.dora_kind(120))
assert_equal(31, GameRoomMahjong::RiichiDeal.dora_kind(132))
assert_equal(8, GameRoomMahjong::RiichiDeal.dora_kind(0, sanma: true))
assert_equal(0, GameRoomMahjong::RiichiDeal.dora_kind(32, sanma: true))
assert_equal(8, GameRoomMahjong::RiichiDeal.dora_count(drawn, winner: 2), 'Two indicators of one kind each count all four physical tiles in the exposed kong')
assert_equal(12, GameRoomMahjong::RiichiDeal.dora_count(drawn, winner: 2, include_ura: true))
assert_raises(ArgumentError) { GameRoomMahjong::RiichiDeal.from_wall((0...144).to_a) }
puts 'PASS Riichi deal: 56 deterministic seat/seed/dealer layouts, live/dead wall counts, dora/ura, kong replenishment and suit/honor/sanma indicator cycles'
