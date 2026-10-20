require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/table_round'
include GameRoomTest::Assertions

def call_round(variant, wall: [96, 97])
  hands = [[16] + (80..92).to_a, [4, 8, 12, 20, 24] + (40..47).to_a,
           [17, 18, 19] + (52..61).to_a, (64..76).to_a]
  flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: wall, seat: 0, phase: :discard)
  GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 0).action(seat: 0, type: :discard, tile: 16, generation: 0)
end

def resolve_call(round, claimant, choice)
  round.window.pending.each do |seat|
    round = round.action(seat: seat, type: :claim, choice: seat == claimant ? choice : [:pass], generation: round.flow.generation)
  end
  round
end

round = resolve_call(call_round('riichi'), 2, [:pung, 4])
assert_equal([4], round.blocked_discards)
assert(round.flow.hands[2].include?(19))
assert(!round.legal_discards.include?(19))
assert_raises(ArgumentError) { round.action(seat: 2, type: :discard, tile: 19, generation: round.flow.generation) }
allowed = round.legal_discards.first
next_round = round.action(seat: 2, type: :discard, tile: allowed, generation: round.flow.generation)
assert_equal([], next_round.blocked_discards)

chow = resolve_call(call_round('riichi'), 1, [:chow, 2])
assert_equal([4, 1], chow.blocked_discards)
assert(chow.flow.hands[1].include?(4))
assert(!chow.legal_discards.include?(4), 'The other end of the called sequence must not be discarded immediately')
assert_raises(ArgumentError) { chow.action(seat: 1, type: :discard, tile: 4, generation: chow.flow.generation) }
hk = resolve_call(call_round('hong_kong'), 2, [:pung, 4])
assert_equal([], hk.blocked_discards)
assert(hk.legal_discards.include?(19), 'Riichi swap-call restrictions must not leak into the HK profile')
furiten_call = call_round('riichi').with(furiten: [false, true, true, false])
after_call = resolve_call(furiten_call, 2, [:pung, 4])
assert_equal([false, true, false, false], after_call.furiten,
  'Only the player making their own call leaves temporary furiten')
assert_equal([false, true, true, false], furiten_call.furiten)

last = call_round('riichi', wall: [])
assert(last.window.offers.values.flatten(1).all? { |choice| %i[pass win].include?(choice.first) }, 'The final discard only permits passing or a win')
assert_raises(ArgumentError) { last.action(seat: 2, type: :claim, choice: [:pung, 4], generation: last.flow.generation) }
puts 'PASS Riichi call rules: immediate same/opposite discard forbidden, legal choices preserved, HK unchanged and final-discard set calls blocked'
