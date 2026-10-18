require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

base = ready_flow('1111m234m567p789s', '5z', self_draw: true)
replacement = base.wall.find { |tile| GameRoomMahjong::Tiles.kind(tile) == 31 }
remaining = base.wall - [replacement]
reserve = [replacement] + remaining.last(13)
flow = GameRoomMahjong::TileFlow.new(hands: base.hands, wall: remaining[0...-13], reserve: reserve,
  replacement_source: :riichi, seat: 0, phase: :discard, last_draw: base.last_draw, draw_origin: :normal)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'riichi', dealer: 1)
assert_equal([0], round.concealed_kongs)
declared = round.action(seat: 0, type: :concealed_kong, tile: 0, generation: flow.generation)
assert_equal(:replacement, declared.flow.phase)
assert_equal(10, declared.flow.hands[0].length)
assert_equal([0, 1, 2, 3], declared.flow.melds[0].first[:tiles])
assert_equal(nil, declared.flow.melds[0].first[:from])
assert_equal([], flow.melds[0])
assert_raises(ArgumentError) { declared.action(seat: 0, type: :win, generation: declared.flow.generation) }
drawn = declared.action(seat: 0, type: :replacement, generation: declared.flow.generation)
assert_equal(11, drawn.flow.hands[0].length)
assert_equal(14, drawn.flow.reserve.length)
assert_equal(2, drawn.flow.dora_indicators.length)
ended = drawn.action(seat: 0, type: :win, generation: drawn.flow.generation)
assert(ended.finished?)
assert_equal(1, ended.result.score.yaku.fetch(:concealed_self_draw))
assert_equal(1, ended.result.score.yaku.fetch(:replacement_draw))
assert_equal(60, ended.result.score.fu, 'The terminal concealed kong must retain concealed fu')
assert_equal(0, ended.result.payments.sum)
assert_raises(ArgumentError) { round.action(seat: 1, type: :concealed_kong, tile: 0, generation: flow.generation) }
assert_raises(ArgumentError) { round.action(seat: 0, type: :concealed_kong, tile: 1, generation: flow.generation) }
assert_equal([], drawn.concealed_kongs)
puts 'PASS concealed kong: owned four copies, closed-hand exposure, mandatory replacement, preserved dead wall, rinshan/closed fu, scored finish and illegal actions'
