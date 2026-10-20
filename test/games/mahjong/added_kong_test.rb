require_relative '../../support/assertions'
require_relative '../../support/mahjong_added_kong'
require_relative '../../../games/mahjong_support/table_events'
include GameRoomTest::Assertions
include MahjongAddedKongFixture

%w[riichi hong_kong mcr].each do |variant|
  flow = added_kong_flow
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 0)
  assert_equal([2], round.added_kongs)
  proposed = round.legal_actions(seat: 1).find { |action| action[:type] == :added_kong }
  codec = GameRoomMahjong::TableEvents
  assert_equal(proposed, codec.selection(codec.to_selection(proposed), round: round, seat: 1))
  pending = round.action(**codec.decode(codec.encode(proposed), seat: 1))
  assert_equal(:kong_reactions, pending.flow.phase)
  assert_equal(:pung, pending.flow.melds[1].first[:type])
  assert_equal(flow.hands, pending.flow.hands, 'Proposing must not consume the fourth tile')
  assert(pending.window.offers[0].include?([:win]))
  assert_equal([], pending.legal_actions(seat: 1))
  assert_raises(ArgumentError) { pending.action(**proposed) }
  assert_raises(ArgumentError) { pending.action(seat: 0, type: :claim, choice: [:chow, 0], generation: pending.flow.generation) }

  robbed = pending
  pending.window.pending.reverse.each do |seat|
    robbed = robbed.action(seat: seat, type: :claim, choice: seat == 0 ? [:win] : [:pass], generation: pending.flow.generation)
  end
  assert(robbed.finished?)
  assert_equal(0, robbed.result.winner)
  assert_equal(1, robbed.result.discarder)
  assert_equal(:pung, robbed.flow.melds[1].first[:type], 'A robbed pung must not become a kong')
  assert(!robbed.flow.hands[1].include?(robbed.result.winning_tile))
  assert_equal([1, robbed.result.winning_tile], robbed.flow.discards.last)
  assert_equal(0, robbed.result.payments.sum)
  score = robbed.result.score
  case variant
  when 'riichi' then assert_equal(1, score.yaku[:robbing_kong])
  when 'hong_kong' then assert_equal(1, score.patterns[:robbing_kong])
  when 'mcr'
    assert(score.patterns.any? { |fan| fan.id == 47 })
    assert(score.patterns.none? { |fan| fan.id == 58 }, 'Robbing does not also count the public pung as Last Tile')
  end

  committed = pending
  pending.window.pending.each do |seat|
    committed = committed.action(seat: seat, type: :claim, choice: [:pass], generation: pending.flow.generation)
  end
  assert_equal(:replacement, committed.flow.phase)
  assert_equal(:kong, committed.flow.melds[1].first[:type])
  assert_equal(4, committed.flow.melds[1].first[:tiles].length)
  assert_equal(2, committed.flow.melds[1].first[:from])
  assert_equal(10, committed.flow.hands[1].length)
  assert_equal(:pung, pending.flow.melds[1].first[:type])
  assert_equal(:discard, round.flow.phase)
  assert_equal(:replacement, committed.bot_action(seat: 1)[:type])
  replaced = committed.action(**committed.bot_action(seat: 1))
  assert_equal(:discard, replaced.flow.phase)
  assert_equal(:replacement, replaced.flow.draw_origin)
end
puts 'PASS added kong: owned exposed pung, delayed physical transfer, all-peer robbery window, three-variant scoring, pass/commit/replacement and immutable stale guards'
