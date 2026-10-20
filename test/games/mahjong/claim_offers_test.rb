require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/claim_offers'
include GameRoomTest::Assertions

# Seat zero discards 5 characters; the next seat can chow 345/456/567,
# while another seat has its three other physical copies.
hands = [[16] + (80..92).to_a, [8, 12, 20, 24] + (40..48).to_a,
         [17, 18, 19] + (52..61).to_a, (64..76).to_a]
flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: [], seat: 0, phase: :discard)
flow = flow.discard(seat: 0, tile: 16, generation: 0)
window = GameRoomMahjong::ClaimOffers.for_discard(flow)
assert_equal([[:pass], [:chow, 2], [:chow, 3], [:chow, 4]], window.offers[1])
assert_equal([[:pass], [:pung, 4]], window.offers[2])
assert_equal([[:pass]], window.offers[3])
assert(window.offers.values.none? { |choices| choices.include?([:win]) }, 'Shape must never bypass scoring validation')
checked = []
window = GameRoomMahjong::ClaimOffers.for_discard(flow, replacement_available: true,
  win_checker: ->(seat, hand, tile) { checked << [seat, hand.length, tile, hand.frozen?]; seat == 3 })
assert(window.offers[2].include?([:kong, 4]))
assert(window.offers[3].include?([:win]))
assert_equal([[1, 13, 4, true], [2, 13, 4, true], [3, 13, 4, true]], checked)
window = window.respond(seat: 1, choice: [:chow, 2], generation: flow.generation)
window = window.respond(seat: 2, choice: [:kong, 4], generation: flow.generation)
window = window.respond(seat: 3, choice: [:win], generation: flow.generation)
assert_equal(:win, window.resolution.type)
assert_raises(ArgumentError) { flow.after_passes(window) }
assert_equal(13, flow.hands[2].length, 'Resolving offers must not transfer tiles before the claim reducer commits')

three = GameRoomMahjong::TileFlow.new(hands: hands.first(3), wall: [], seat: 0, phase: :discard)
three = three.discard(seat: 0, tile: 16, generation: 0)
assert(GameRoomMahjong::ClaimOffers.for_discard(three).offers.values.flatten(1).none? { |choice| choice.first == :chow })
assert_raises(ArgumentError) { GameRoomMahjong::ClaimOffers.for_discard(flow, replacement_available: 'yes') }
puts 'PASS mahjong claim offers: owned copies, chow seat/suit, replacement-gated kong, scoring-gated wins and claim priority'
