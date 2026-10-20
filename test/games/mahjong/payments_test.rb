require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/payments'
include GameRoomTest::Assertions
payments = GameRoomMahjong::Payments

assert_equal([-3900, 3900, 0, 0], payments.riichi(han: 3, fu: 30, winner: 1, dealer: 0, discarder: 0))
assert_equal([5800, -5800, 0, 0], payments.riichi(han: 3, fu: 30, winner: 0, dealer: 0, discarder: 1))
assert_equal([-2000, 4000, -1000, -1000], payments.riichi(han: 3, fu: 30, winner: 1, dealer: 0))
assert_equal([-8000, 8000, 0, 0], payments.riichi(han: 3, fu: 60, winner: 1, dealer: 0, discarder: 0))
assert_equal([-7700, 7700, 0, 0], payments.riichi(han: 3, fu: 60, winner: 1, dealer: 0, discarder: 0, kiriage: false))
assert_equal([18000, -18000, 0, 0], payments.riichi(han: 6, fu: 30, winner: 0, dealer: 0, discarder: 1))
assert_equal([32000, -32000, 0, 0], payments.riichi(han: 0, fu: 30, yakuman: 1, winner: 0, dealer: 1, discarder: 1))
assert_equal([32000, -32000, 0, 0], payments.riichi(han: 0, fu: 0, yakuman: 1, winner: 0, dealer: 1, discarder: 1))
assert_equal([-32000, 48000, -16000], payments.riichi(han: 0, fu: 30, yakuman: 2, winner: 1, dealer: 0, seats: 3))
assert_equal([-2000, 3000, -1000], payments.riichi(han: 3, fu: 30, winner: 1, dealer: 0, seats: 3))
assert_equal([-4200, 4200, 0, 0], payments.riichi(han: 3, fu: 30, winner: 1, dealer: 0, discarder: 0, honba: 1))
assert_equal([-2100, 4300, -1100, -1100], payments.riichi(han: 3, fu: 30, winner: 1, dealer: 0, honba: 1))
assert_equal([3000, -1000, -1000, -1000], payments.riichi_draw(tenpai: [true, false, false, false]))
assert_equal([1500, 1500, -1500, -1500], payments.riichi_draw(tenpai: [true, true, false, false]))
assert_equal([-2000, 1000, 1000], payments.riichi_draw(tenpai: [false, true, true], seats: 3))
assert_equal([0, 0, 0, 0], payments.riichi_draw(tenpai: [true] * 4))
assert_equal([-18, 34, -8, -8], payments.mcr(fan: 8, flowers: 2, winner: 1, discarder: 0))
assert_equal([-18, 54, -18, -18], payments.mcr(fan: 8, flowers: 2, winner: 1))
assert_equal([-16, 32, -8, -8], payments.hong_kong(fan: 3, minimum: 3, winner: 1, discarder: 0))
assert_equal([-16, 48, -16, -16], payments.hong_kong(fan: 3, minimum: 3, winner: 1))
assert_raises(ArgumentError) { payments.mcr(fan: 7, flowers: 8, winner: 0) }
assert_raises(ArgumentError) { payments.riichi(han: 0, fu: 30, winner: 0, dealer: 0) }
assert_raises(ArgumentError) { payments.riichi(han: 3, fu: 22, winner: 0, dealer: 0) }
assert_raises(ArgumentError) { payments.riichi(han: 3, fu: 30, winner: 0, dealer: 0, discarder: 0) }
assert_raises(ArgumentError) { payments.hong_kong(fan: 2, minimum: 3, winner: 0) }

puts 'PASS mahjong payments: riichi fu/han limits, kiriage, honba, sanma tsumo loss, exhaustive draws, MCR minimum and Hong Kong half-pay'
