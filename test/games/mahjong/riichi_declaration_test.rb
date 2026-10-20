require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/table_events'
include GameRoomTest::Assertions
include MahjongRoundFixture

def all_pass(round)
  round.window.pending.each do |seat|
    round = round.action(seat: seat, type: :claim, choice: [:pass], generation: round.flow.generation)
  end
  round
end

flow = ready_flow('123m456p789s1112z', '5z', self_draw: true)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'riichi', dealer: 0)
action = round.legal_actions(seat: 0).find { |choice| choice[:type] == :riichi && choice[:tile] == flow.last_draw }
assert(action)
codec = GameRoomMahjong::TableEvents
assert_equal(action, codec.selection(codec.to_selection(action), round: round, seat: 0))
pending = round.action(**codec.decode(codec.encode(action), seat: 0))
assert_equal(0, pending.riichi_state.levels[0])
assert_equal(30000, pending.riichi_state.points[0])
accepted = all_pass(pending)
assert_equal(2, accepted.riichi_state.levels[0])
assert_equal(29000, accepted.riichi_state.points[0])
assert_equal(1, accepted.riichi_state.sticks)
assert_equal(true, accepted.riichi_state.ippatsu[0])
assert_equal(nil, accepted.pending_riichi)
assert_equal(30000, round.riichi_state.points[0])

current = accepted
until current.flow.seat == 0 && current.flow.phase == :draw
  case current.flow.phase
  when :draw
    current = current.action(seat: current.flow.seat, type: :draw, generation: current.flow.generation)
  when :discard
    current = current.action(seat: current.flow.seat, type: :discard, tile: current.flow.last_draw, generation: current.flow.generation)
  when :reactions
    current = all_pass(current)
  end
end
current = current.action(seat: 0, type: :draw, generation: current.flow.generation)
assert_equal([current.flow.last_draw], current.legal_discards)
assert_equal([], current.riichi_discards)
assert_equal([], current.concealed_kongs)
assert_equal(true, current.riichi_state.ippatsu[0])
assert_raises(ArgumentError) do
  current.action(seat: 0, type: :discard, tile: current.flow.hands[0].find { |tile| tile != current.flow.last_draw }, generation: current.flow.generation)
end
discarded = current.action(seat: 0, type: :discard, tile: current.flow.last_draw, generation: current.flow.generation)
assert_equal(false, discarded.riichi_state.ippatsu[0])

ron = ready_flow('123m456p789s1112z', '2z')
ready = GameRoomMahjong::TableRound.new(flow: ron, variant: 'riichi', dealer: 0, riichi_state: accepted.riichi_state)
window = GameRoomMahjong::ClaimOffers.for_discard(ron,
  win_checker: ->(seat, _hand, _tile) { !ready.winning_result(seat).nil? })
passed = all_pass(ready.with(window: window))
assert_equal(true, passed.riichi_state.furiten[0])
again = ready.with(riichi_state: passed.riichi_state)
assert_equal(nil, again.winning_result(0))
self_draw = ready_flow('123m456p789s1112z', '2z', self_draw: true)
tsumo = GameRoomMahjong::TableRound.new(flow: self_draw, variant: 'riichi', dealer: 0, riichi_state: passed.riichi_state)
assert(tsumo.winning_result(0), 'Riichi furiten does not block self draw')
won = tsumo.action(seat: 0, type: :win, generation: self_draw.generation)
assert_equal(0, won.riichi_outcome.sticks)
assert_equal(0, won.result.payments.sum)
assert_equal(2, won.result.score.yaku[:double_riichi])

# A ron on the declaration discard voids the declaration and deposit.
counts = Hash.new(0)
take = ->(kind) { tile = kind * 4 + counts[kind]; counts[kind] += 1; raise 'Too many copies' if counts[kind] > 4; tile }
hands = ['123m456p789s1112z5z', '123456789m3335z'].map { |text| mahjong_kinds(text).map { |kind| take.call(kind) } }
rest = (0...136).to_a - hands.flatten
hands.concat([rest.shift(13), rest.shift(13)])
void_flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: rest, seat: 0, phase: :discard,
  last_draw: hands[0].last, draw_origin: :normal)
void_round = GameRoomMahjong::TableRound.new(flow: void_flow, variant: 'riichi', dealer: 0)
void_round = void_round.action(seat: 0, type: :riichi, tile: void_flow.last_draw, generation: void_flow.generation)
assert(void_round.window.offers[1].include?([:win]))
void_round.window.pending.each do |seat|
  void_round = void_round.action(seat: seat, type: :claim, choice: seat == 1 ? [:win] : [:pass], generation: void_round.flow.generation)
end
assert(void_round.finished?)
assert_equal([0, 0, 0, 0], void_round.riichi_state.levels)
assert_equal(0, void_round.riichi_outcome.sticks)
assert_equal(0, void_round.result.payments.sum)
assert_equal([30000] * 4, void_round.riichi_state.points)
puts 'PASS coordinated riichi: declaration barrier, void-on-ron deposit, double riichi, locked discard, ippatsu expiry, permanent furiten and winner deposit recovery'
