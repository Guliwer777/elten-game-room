require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

%w[riichi hong_kong].each do |variant|
  flow = ready_flow('123456m23455p67s', '8s', self_draw: true)
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 1)
  ended = round.action(seat: 0, type: :win, generation: flow.generation)
  assert(ended.finished?)
  assert(!round.finished?, 'Ending a round must not mutate earlier history')
  assert_equal(0, ended.result.payments.sum)
  assert_raises(ArgumentError) { ended.action(seat: 0, type: :discard, tile: flow.hands[0].first, generation: flow.generation) }
end
mcr_flow = ready_flow('123456789m1115z', '5z', self_draw: true)
mcr_round = GameRoomMahjong::TableRound.new(flow: mcr_flow, variant: 'mcr', dealer: 0)
mcr_finished = mcr_round.action(seat: 0, type: :win, generation: mcr_flow.generation)
assert(mcr_finished.finished?)
assert_equal(31, mcr_finished.result.score.fan)
assert_equal([117, -39, -39, -39], mcr_finished.result.payments)

# A normal discard builds scoring-validated offers, waits for every response,
# and then settles the winning claim instead of advancing to another draw.
flow = ready_flow('123456789m1115z', '5z')
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'hong_kong', dealer: 1)
window = GameRoomMahjong::ClaimOffers.for_discard(flow,
  win_checker: ->(seat, _hand, _kind) { !round.winning_result(seat).nil? })
round = round.with(window: window)
assert(window.offers[0].include?([:win]))
window.pending.each do |seat|
  before = round
  round = round.action(seat: seat, type: :claim, choice: seat == 0 ? [:win] : [:pass], generation: flow.generation)
  assert_equal(nil, before.result)
end
assert(round.finished?)
assert_equal(0, round.result.winner)
assert_equal(1, round.result.discarder)
assert_equal(0, round.result.payments.sum)

# Complete an ordinary no-call round using the same action coordinator.
tiles = GameRoomMahjong::Tiles.set
flow = GameRoomMahjong::TileFlow.new(hands: 4.times.map { |seat| tiles.slice(seat * 13, 13) }, wall: tiles.drop(52), seat: 0)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'riichi', dealer: 0)
steps = 0
until round.finished?
  generation, seat = round.flow.generation, round.flow.seat
  case round.flow.phase
  when :draw
    round = round.action(seat: seat, type: :draw, generation: generation)
  when :discard
    round = round.action(seat: seat, type: :discard, tile: round.flow.last_draw, generation: generation)
  when :reactions
    responding = round.window.pending.first
    round = round.action(seat: responding, type: :claim, choice: [:pass], generation: generation)
  end
  steps += 1
  raise 'Round did not terminate' if steps > 600
end
assert_equal(:exhausted, round.flow.phase)
assert_equal(84, round.flow.discards.length)
assert(round.result.draw?)
assert_equal(0, round.result.payments.sum)
assert_equal(4, round.result.tenpai.length)
puts 'PASS mahjong table round: coordinated draw/discard/responses, scoring-approved discard win, self-draw win, immutable finish and full exhaustive round'
