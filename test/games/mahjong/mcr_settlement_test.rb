require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

def mcr_reframe(flow, **changes)
  fields = %i[hands wall seat phase generation discards melds reserve flowers replacement_source replacement_draws last_draw draw_origin discard_history]
  GameRoomMahjong::TileFlow.new(**fields.to_h { |key| [key, flow.public_send(key)] }.merge(changes))
end

def settle_mcr(flow)
  GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'mcr', winner: 0, dealer: 0)
end

ron = ready_flow('123456789m1115z', '5z')
result = settle_mcr(ron)
assert_equal(29, result.score.fan)
assert_equal(1, result.discarder)
assert_equal([53, -37, -8, -8], result.payments)
flowers = mcr_reframe(ron, flowers: [[136, 137], [], [], []])
flower_result = settle_mcr(flowers)
assert_equal(result.score.fan, flower_result.score.fan)
assert_equal(2, flower_result.score.flowers)
assert_equal([55, -39, -8, -8], flower_result.payments)

weak = ready_flow('123456m23455p67s', '8s', self_draw: true)
assert_equal(nil, settle_mcr(mcr_reframe(weak, flowers: [(136..143).to_a, [], [], []])),
  'Eight flowers cannot qualify a seven-fan hand')

drawn = ready_flow('123456789m1115z', '5z', self_draw: true)
direct = settle_mcr(mcr_reframe(drawn, draw_origin: :replacement))
after_flower = settle_mcr(mcr_reframe(drawn, draw_origin: :flower_replacement, flowers: [[136], [], [], []]))
assert(direct.score.patterns.any? { |fan| fan.id == 46 })
assert(after_flower.score.patterns.none? { |fan| fan.id == 46 }, 'Flower replacement is not direct kong replacement')
assert_equal(1, after_flower.score.flowers)
last = settle_mcr(mcr_reframe(drawn, wall: [], draw_origin: :flower_replacement))
assert(last.score.patterns.any? { |fan| fan.id == 44 })
assert(last.score.patterns.none? { |fan| fan.id == 46 })

# Three older public copies qualify Last Tile, but the just-winning discard
# itself must not be counted as one of those three older visible copies.
kind = GameRoomMahjong::Tiles.kind(ron.discards.last.last)
other_copies = (kind * 4...kind * 4 + 4).to_a - ron.hands[0] - [ron.discards.last.last]
hands = ron.hands.map { |hand| hand - other_copies }
pool = ron.wall - other_copies
hands.each_with_index { |hand, seat| hand << pool.shift while hand.length < ron.hands[seat].length }
older = other_copies.map { |tile| [2, tile] }
visible = mcr_reframe(ron, hands: hands, wall: pool, discards: older + ron.discards,
  discard_history: older + ron.discard_history)
assert(settle_mcr(visible).score.patterns.none? { |fan| fan.id == 58 },
  'A pair wait leaves only two earlier public copies, not three')
single = ready_flow('12m456789m11155z', '3m')
kind = GameRoomMahjong::Tiles.kind(single.discards.last.last)
copies = (kind * 4...kind * 4 + 4).to_a - [single.discards.last.last]
hands = single.hands.map { |hand| hand - copies }
pool = single.wall - copies
hands.each_with_index { |hand, seat| hand << pool.shift while hand.length < single.hands[seat].length }
older = copies.map { |tile| [2, tile] }
public_three = mcr_reframe(single, hands: hands, wall: pool, discards: older + single.discards,
  discard_history: older + single.discard_history)
assert(settle_mcr(public_three).score.patterns.any? { |fan| fan.id == 58 },
  'Three older visible copies qualify the actual fourth winning tile')
assert_raises(ArgumentError) do
  GameRoomMahjong::RoundSettlement.win(flow: ron, variant: 'mcr', winner: 0, dealer: 0, flowers: [34])
end
assert_equal(0, flower_result.payments.sum)
round = GameRoomMahjong::TableRound.new(flow: ron, variant: 'mcr', dealer: 0)
window = GameRoomMahjong::ClaimOffers.for_discard(ron,
  win_checker: ->(seat, _hand, _kind) { !round.winning_result(seat).nil? })
round = round.with(window: window)
assert(window.offers[0].include?([:win]))
window.pending.reverse.each do |seat|
  previous = round
  round = round.action(seat: seat, type: :claim, choice: seat == 0 ? [:win] : [:pass], generation: ron.generation)
  assert_equal(nil, previous.result)
end
assert(round.finished?)
assert_equal(result.payments, round.result.payments)
assert_raises(ArgumentError) do
  round.action(seat: 0, type: :claim, choice: [:win], generation: ron.generation)
end
puts 'PASS internal MCR settlement: discard payments, owned flowers, non-flower threshold, replacement origin and last-tile context'
