require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

def declared_for(text)
  flow = ready_flow(text, '7z', self_draw: true)
  ledger = GameRoomMahjong::RiichiState.new(points: [30000] * 4)
  ledger.accept(ledger.declaration(flow: flow, seat: 0, tile: flow.last_draw))
end

before = '111z123m456p789s2z'
state = declared_for(before)
drawn = ready_flow(before, '1z', self_draw: true)
assert(state.concealed_kong_allowed?(flow: drawn, seat: 0, kind: 27))
flow = GameRoomMahjong::TileFlow.new(hands: drawn.hands, wall: drawn.wall.drop(1), reserve: drawn.wall.first(1),
  seat: 0, phase: :discard, last_draw: drawn.last_draw, draw_origin: :normal)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'riichi', dealer: 0, riichi_state: state)
assert_equal([27], round.concealed_kongs)
kong = round.action(seat: 0, type: :concealed_kong, tile: 27, generation: flow.generation)
assert_equal(:replacement, kong.flow.phase)
assert_equal(false, kong.riichi_state.ippatsu[0])
assert_equal(state.waits, kong.riichi_state.waits)

# Pair/closed-wait ambiguity: a quad cannot remove a legal interpretation.
ambiguous = '1113s456m789p555z'
state = declared_for(ambiguous)
flow = ready_flow(ambiguous, '1s', self_draw: true)
assert_equal(false, state.concealed_kong_allowed?(flow: flow, seat: 0, kind: 18))

# Actual waits remain unchanged, but an interpretation needing a fifth 5s
# changes the 1s triplet into a pair/chow. WRC explicitly includes this case.
virtual = '1112223335555s'
state = declared_for(virtual)
flow = ready_flow(virtual, '1s', self_draw: true)
before_kinds = mahjong_kinds(virtual)
after = before_kinds.dup
3.times { after.delete_at(after.index(18)) }
assert_equal(state.waits[0], GameRoomMahjong::Hand.waits(after, melds: [[:kong, 18]]))
assert(state.waits[0].all? { |tile| GameRoomMahjong::Hand.forms(before_kinds + [tile]).all? { |form| form.groups.include?([:pung, 18]) } },
  'Every physically possible win preserves the triplet in this fixture')
assert_equal(false, state.concealed_kong_allowed?(flow: flow, seat: 0, kind: 18),
  'Equal physical waits alone cannot authorize a post-riichi kong')
assert(GameRoomMahjong::Hand.virtual_win_forms(before_kinds).any? { |form| form.type == :standard && !form.groups.include?([:pung, 18]) })
assert_raises(ArgumentError) { GameRoomMahjong::Hand.forms(before_kinds + [22]) }

# A quad held before this draw is not eligible after riichi.
old_quad = ready_flow('1111z123m456p789s', '2z', self_draw: true)
assert_equal(false, declared_for(before).concealed_kong_allowed?(flow: old_quad, seat: 0, kind: 27))
puts 'PASS post-riichi kong: current drawn fourth tile, identical waits and all structures, fifth-copy virtual ambiguity rejected, ippatsu cancelled without changing locked waits'
