require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/riichi_state'
include GameRoomTest::Assertions
include MahjongRoundFixture

state = GameRoomMahjong::RiichiState.new(points: [500, 30000, 30000, 30000])
flow = ready_flow('123m456p789s1112z', '5z', self_draw: true)
declaration = state.declaration(flow: flow, seat: 0, tile: flow.last_draw)
assert(declaration)
assert_equal(2, declaration[:level])
assert_equal([28], declaration[:waits])
assert(declaration.frozen? && declaration[:waits].frozen?)
assert_equal(nil, state.declaration(flow: flow, seat: 1, tile: flow.last_draw))
assert_equal(nil, state.declaration(flow: flow, seat: 0, tile: 135))
assert_equal(nil, state.declaration(flow: flow, seat: 0, tile: flow.hands[0].first))
accepted = state.accept(declaration)
assert_equal([-500, 30000, 30000, 30000], accepted.points)
assert_equal(1, accepted.sticks)
assert_equal([true, false, false, false], accepted.ippatsu)
assert_equal([0, 0, 0, 0], state.levels)
assert_equal(0, state.sticks, 'A declaration discard won by another seat must never call accept or lose a deposit')
assert_raises(ArgumentError) { accepted.accept(declaration) }
assert_equal(nil, accepted.declaration(flow: flow, seat: 0, tile: flow.last_draw))

ordinary = ready_flow('123m456p789s1112z', '5z', self_draw: true, own_discard: '9p')
assert_equal(1, state.declaration(flow: ordinary, seat: 0, tile: ordinary.last_draw)[:level])
last_flow = GameRoomMahjong::TileFlow.new(hands: flow.hands, wall: [], seat: 0, phase: :discard,
  last_draw: flow.last_draw, draw_origin: :normal)
assert(state.declaration(flow: last_flow, seat: 0, tile: last_flow.last_draw), 'WRC2025 permits riichi on the last live tile')
assert_equal([false] * 4, accepted.interrupt.ippatsu)
assert_equal([false] * 4, accepted.after_discard(seat: 0).ippatsu)
assert_equal([true, false, false, false], accepted.after_discard(seat: 1).ippatsu)
furiten = accepted.pass_ron(seat: 0)
assert_equal([true, false, false, false], furiten.furiten)
assert_equal(furiten.furiten, furiten.interrupt.after_discard(seat: 0).furiten,
  'Riichi furiten survives calls and later own discards')
assert(state.equal?(state.pass_ron(seat: 0)), 'An undeclared player uses ordinary temporary furiten instead')

win = accepted.settle(payments: [-1000, 1000, 0, 0], winner: 1)
assert_equal([-1500, 32000, 30000, 30000], win.points)
assert_equal([-2000, 2000, 0, 0], win.delta)
assert_equal(0, win.sticks)
assert_equal(state.points.sum, win.points.sum)
draw = accepted.settle(payments: [3000, -1000, -1000, -1000])
assert_equal(1, draw.sticks)
assert_equal(state.points.sum, draw.points.sum + draw.sticks * 1000)
assert_equal(-1000, draw.delta.sum)
assert(win.frozen? && win.points.frozen? && win.delta.frozen?)
assert_raises(ArgumentError) { accepted.settle(payments: [1, 0, 0, 0], winner: 0) }
assert_raises(ArgumentError) { accepted.pass_ron(seat: -1) }
assert_raises(ArgumentError) { GameRoomMahjong::RiichiState.new(points: [30000] * 4, levels: [1.0, 0, 0, 0]) }
puts 'PASS riichi accepted facts: ready discard, first uninterrupted turn, last-tile/negative-balance declaration, deposit ledger, ippatsu interruption and permanent furiten'
