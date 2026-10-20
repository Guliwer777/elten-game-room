require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/match_state'
include GameRoomTest::Assertions
include MahjongRoundFixture

def winning_match_round(match, winner: 0)
  base = ready_flow('123456789m1115z', '5z', self_draw: true)
  hands = base.hands.rotate(-winner)
  flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: base.wall, seat: winner, phase: :discard,
    last_draw: base.last_draw, draw_origin: :normal)
  ledger = match.variant == 'riichi' ? GameRoomMahjong::RiichiState.new(points: match.points, sticks: match.sticks) : nil
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: match.variant, dealer: match.dealer,
    round_wind: match.round_wind, honba: match.honba, riichi_state: ledger)
  round.action(seat: winner, type: :win, generation: flow.generation)
end

def draw_match_round(match, dealer_ready:)
  round = match.next_round(seed: 42)
  ready = Array.new(match.seats, false)
  ready[match.dealer] = dealer_ready
  # Accepted-result fixture isolates progression from the already separately
  # tested exhaustive-wall and tenpai calculator.
  result = GameRoomMahjong::RoundSettlement::Result.new(payments: Array.new(match.seats, 0).freeze, tenpai: ready.freeze).freeze
  round.finish_with(result)
end

mcr = GameRoomMahjong::MatchState.new(variant: 'mcr')
16.times do |index|
  assert_equal(index % 4, mcr.dealer)
  assert_equal(27 + index / 4, mcr.round_wind)
  before = mcr
  ended = winning_match_round(mcr, winner: mcr.dealer)
  mcr = mcr.advance(round: ended, hand_number: index + 1)
  assert_equal(index, before.hand_number)
  assert_equal(0, mcr.points.sum)
end
assert(mcr.finished?)
assert_equal(16, mcr.hand_number)
assert_raises(ArgumentError) { mcr.next_round(seed: 1) }

hk = GameRoomMahjong::MatchState.new(variant: 'hong_kong', winds: 1)
hk = hk.advance(round: winning_match_round(hk), hand_number: 1)
assert_equal(0, hk.dealer)
assert_equal(0, hk.rotations)
hk = hk.advance(round: draw_match_round(hk, dealer_ready: false), hand_number: 2)
assert_equal(0, hk.dealer)
4.times do
  hk = hk.advance(round: winning_match_round(hk, winner: (hk.dealer + 1) % 4), hand_number: hk.hand_number + 1)
end
assert(hk.finished?)
assert_equal(6, hk.hand_number)

riichi = GameRoomMahjong::MatchState.new(variant: 'riichi', winds: 1)
riichi = riichi.advance(round: winning_match_round(riichi), hand_number: 1)
assert_equal([0, 0, 1], [riichi.dealer, riichi.rotations, riichi.honba])
riichi = riichi.advance(round: draw_match_round(riichi, dealer_ready: true), hand_number: 2)
assert_equal([0, 0, 2], [riichi.dealer, riichi.rotations, riichi.honba])
riichi = riichi.advance(round: draw_match_round(riichi, dealer_ready: false), hand_number: 3)
assert_equal([1, 1, 3], [riichi.dealer, riichi.rotations, riichi.honba])
ended = winning_match_round(riichi, winner: 2)
before = riichi
riichi = riichi.advance(round: ended, hand_number: 4)
assert_equal([2, 2, 0], [riichi.dealer, riichi.rotations, riichi.honba])
assert_raises(ArgumentError) { riichi.advance(round: ended, hand_number: 4) }
assert_equal(3, before.honba)

# A draw retains a real deposit, and the next hand's winner collects it.
carry = GameRoomMahjong::MatchState.new(variant: 'riichi', points: [29000, 30000, 30000, 30000],
  initial_points: [30000] * 4, sticks: 1)
drawn = draw_match_round(carry, dealer_ready: false)
carry = carry.advance(round: drawn, hand_number: 1)
assert_equal(1, carry.sticks)
next_round = carry.next_round(seed: 52)
assert_equal(carry.points, next_round.riichi_state.points)
assert_equal(1, next_round.riichi_state.sticks)
paid = carry.advance(round: winning_match_round(carry, winner: 2), hand_number: 2)
assert_equal(0, paid.sticks)
assert_equal(120000, paid.points.sum)
assert_equal(0, paid.scores.sum)
assert(carry.points.frozen? && paid.scores.frozen?)
sanma = GameRoomMahjong::MatchState.new(variant: 'riichi', seats: 3).next_round(seed: 1)
assert_equal(3, sanma.flow.hands.length)
assert_raises(ArgumentError) { GameRoomMahjong::MatchState.new(variant: 'mcr', seats: 3) }
puts 'PASS Mahjong match progression: sixteen MCR hands, HK dealer repeats, Riichi tenpai continuance/honba, stale hand rejection and deposit carry to the next winner'
