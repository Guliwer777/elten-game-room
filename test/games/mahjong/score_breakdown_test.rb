require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

# Reproduce the reported 16+1 win with all three earlier Easts public.
base = ready_flow('47m258p369s24567z', '1z')
kind = GameRoomMahjong::Tiles.kind(base.discards.last.last)
copies = (kind * 4...kind * 4 + 4).to_a - [base.discards.last.last]
hands = base.hands.map { |hand| hand - copies }
pool = base.wall - copies - [143]
hands.each_with_index { |hand, seat| hand << pool.shift while hand.length < base.hands[seat].length }
older = copies.map { |tile| [2, tile] }
flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: pool, seat: base.seat, phase: base.phase,
  discards: older + base.discards, discard_history: older + base.discard_history, flowers: [[143], [], [], []])
result = GameRoomMahjong::RoundSettlement.win(flow: flow, variant: 'mcr', winner: 0, dealer: 0)
assert_equal([34,58], result.score.patterns.map(&:id))
assert_equal(16,result.score.fan)
assert_equal(1,result.score.flowers)
assert_equal([41,-25,-8,-8],result.payments)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'mcr', dealer: 0, result: result)
game = GameRoomGames::Mahjong::Table.new
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  text = game.send(:mahjong_score_breakdown, round)
  assert(text.include?('16') && text.include?('17') && text.include?('12') && text.include?('4'))
  assert(!text.include?('MCR 34:') && !text.include?('MCR 58:'))
  if language == 'pl'
    assert(text.include?('Ręka: 16 fan') && text.include?('do rozliczenia: 17 fan'))
    assert(text.include?('Mniejszy układ') && text.include?('Ostatni egzemplarz'))
  end
  spec = game.table_surface_spec(round, players: %w[A B C D], viewer: 'B')
  assert(spec.parts.any? { |part| part.id == 'value' })
end
# Other variants explain selected awards, never speculative/replaced ones.
%w[hong_kong riichi].each do |variant|
  flow = ready_flow('19m19p19s1234567z', '1m')
  settlement = GameRoomMahjong::RoundSettlement.win(flow: flow, variant: variant, winner: 0, dealer: 0)
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 0, result: settlement)
  %w[en pl cs es ru].each do |language|
    NativeOptionTest.language = language
    assert(!game.send(:mahjong_score_breakdown, round).empty?)
  end
end
puts 'PASS accepted winning score breakdown: reported MCR 12+4+1, payment total17, all languages/spectator result, HK/Riichi selected awards'


# Ordinary multi-component hands exercise Riichi wind/yaku mapping too.
%w[hong_kong riichi].each do |variant|
  flow = ready_flow('123456789m1115z', '5z')
  result = GameRoomMahjong::RoundSettlement.win(flow: flow, variant: variant, winner: 0, dealer: 0)
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 0, result: result)
  %w[en pl cs es ru].each do |language|
    NativeOptionTest.language = language
    text = game.send(:mahjong_score_breakdown, round)
    assert(text.lines.length >= 2)
    assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?)
  end
end
