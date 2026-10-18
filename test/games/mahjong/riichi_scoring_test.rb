require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../../games/mahjong_support/riichi_scoring'
include GameRoomTest::Assertions
include MahjongTestTiles

def score(text, tile, **context)
  GameRoomMahjong::RiichiScoring.score(concealed: mahjong_kinds(text), winning_tile: mahjong_kinds(tile).first, **context)
end

result = score('123456m23455p678s', '8s', riichi: 1)
assert_equal(2, result.han)
assert_equal(30, result.fu)
assert_equal({riichi: 1, pinfu: 1}, result.yaku)
result = score('123456m23455p678s', '8s', self_draw: true)
assert_equal(2, result.han)
assert_equal(20, result.fu, 'Pinfu self-draw is the special 20-fu case')
assert_equal(:two_sided, result.wait)
assert_equal(nil, score('456m23455p678s', '8s', melds: [[:chow, 0, true]], dora: 3), 'Dora cannot provide the required yaku')
result = score('456m23455p678s', '8s', melds: [[:chow, 1, true]])
assert_equal({all_simples: 1}, result.yaku)
assert_equal(30, result.fu, 'An open all-chow hand is at least 30 fu')
result = score('1122m4455p7788s33z', '3z', riichi: 1)
assert_equal(25, result.fu)
assert_equal(3, result.han)
assert_equal(:seven_pairs, result.form.type)
result = score('222m44555p666777s', '7s')
assert_equal(0, result.yakuman)
assert_equal(5, result.han)
assert_equal(50, result.fu)
result = score('222m44555p666777s', '7s', self_draw: true)
assert_equal(1, result.yakuman, 'Four concealed pungs on self-draw is yakuman')
result = score('222m44555p666777s', '4p')
assert_equal(1, result.yakuman, 'Four concealed pungs may win by discard on the pair')
result = score('222m123456p789s11z', '7s', self_draw: true)
assert_equal(30, result.fu, 'A double-wind pair gives two fu in the selected EMA-2025 scoring profile')
result = score('19m19p19s12345677z', '7z')
assert_equal(1, result.yakuman)
assert_equal(:thirteen_orphans, result.form.type)
result = score('11123456789995m', '5m')
assert_equal(1, result.yakuman)
assert(result.yaku.key?(:nine_gates))
result = score('11122233344455z', '5z')
assert_equal(3, result.yakuman, 'All honors, big four winds and four concealed pungs stack')
result = score('22233344466688s', '8s')
assert(result.yaku.key?(:all_green))
result = score('123m123p123s789s55p', '9s')
assert_equal(3, result.han, 'Closed mixed triple chow combines with pinfu')
result = score('123456789m234p55s', '4p')
assert_equal(3, result.han, 'Closed pure straight combines with pinfu')
assert_equal(nil, score('123456m23455p678s', '5p'), 'Pair wait removes pinfu; this hand has no other yaku')
result = score('123456m23455p678s', '8s', riichi: 2, dora: 2, flags: {ippatsu: true})
assert_equal(6, result.han)
assert_raises(ArgumentError) { score('456m23455p678s', '8s', melds: [[:chow, 0, true]], riichi: 1) }
assert_raises(ArgumentError) { score('123456m23455p678s', '8s', flags: {ippatsu: true}) }
assert_raises(ArgumentError) { score('123456m23455p678s', '8s', flags: {replacement: true}) }
assert_raises(ArgumentError) { score('123456m23455p678s', '9m') }
puts 'PASS riichi scoring: real yaku versus dora, wait-dependent fu, exposed/concealed sets, ambiguous forms and yakuman'
