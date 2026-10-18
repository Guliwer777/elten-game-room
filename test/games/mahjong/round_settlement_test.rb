require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/round_settlement'
include GameRoomTest::Assertions
include MahjongRoundFixture

flow = ready_flow('123456m23455p67s', '8s', self_draw: true)
riichi = GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'riichi', winner: 0, dealer: 1)
assert_equal(2, riichi.score.han)
assert_equal(20, riichi.score.fu)
assert_equal(nil, riichi.discarder)
assert_equal(flow.last_draw, riichi.winning_tile)
assert_equal(0, riichi.payments.sum)
assert(riichi.payments[0].positive?)
hk = GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'hong_kong', winner: 0, dealer: 1)
assert_equal(3, hk.score.fan)
assert_equal([48, -16, -16, -16], hk.payments)
assert_equal(nil, GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'mcr', winner: 0, dealer: 1), 'Seven fan must fail the MCR minimum')

ron = ready_flow('123456m23455p67s', '8s')
result = GameRoomMahjong::RoundSettlement.win(flow: ron, variant: 'riichi', winner: 0, dealer: 1, riichi: 1)
assert_equal(1, result.discarder)
assert_equal([2000, -2000, 0, 0], result.payments)
assert_equal(nil, GameRoomMahjong::RoundSettlement.win(flow: ron, variant: 'riichi', winner: 0, dealer: 1, riichi: 1, temporary_furiten: true))
furiten = ready_flow('123456m23455p67s', '8s', own_discard: '5s')
assert_equal(nil, GameRoomMahjong::RoundSettlement.win(flow: furiten, variant: 'riichi', winner: 0, dealer: 1, riichi: 1), 'Any own discarded wait blocks ron, not only the currently offered tile')
tsumo_furiten = ready_flow('123456m23455p67s', '8s', self_draw: true, own_discard: '5s')
assert(GameRoomMahjong::RoundSettlement.win(flow: tsumo_furiten, variant: 'riichi', winner: 0, dealer: 1, temporary_furiten: true), 'Furiten does not block self draw')
assert_raises(ArgumentError) { GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'riichi', winner: 2, dealer: 1) }
assert_raises(ArgumentError) { GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'hong_kong', winner: 0, dealer: 1, dora: 1) }
counts = Hash.new(0)
hands = ['123456m23455p67s'] + Array.new(3, '123m147p147s1234z')
physical_hands = hands.map do |text|
  mahjong_kinds(text).map do |kind|
    physical = kind * 4 + counts[kind]
    counts[kind] += 1
    physical
  end
end
exhausted = GameRoomMahjong::TileFlow.new(hands: physical_hands, wall: [], seat: 0, phase: :exhausted)
draw = GameRoomMahjong::RoundSettlement.draw(flow: exhausted, variant: 'riichi')
assert(draw.draw?)
assert_equal([true, false, false, false], draw.tenpai)
assert_equal([3000, -1000, -1000, -1000], draw.payments)
assert_equal([0, 0, 0, 0], GameRoomMahjong::RoundSettlement.draw(flow: exhausted, variant: 'hong_kong').payments)
assert_raises(ArgumentError) { GameRoomMahjong::RoundSettlement.draw(flow: ron, variant: 'riichi') }
assert_raises(ArgumentError) { GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'riichi', winner: 0, dealer: 1, riichi: 'yes') }
puts 'PASS mahjong round settlement: actual winning draw/discard, Riichi/HK scorer bridge, zero-sum payments, own-wait and temporary furiten, MCR minimum rejection'
