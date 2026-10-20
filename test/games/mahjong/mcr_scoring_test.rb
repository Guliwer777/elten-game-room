require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../../games/mahjong_support/mcr_scoring'
include GameRoomTest::Assertions
include MahjongTestTiles

def mcr_score(text, winning, **context)
  GameRoomMahjong::MCRScoring.score(concealed: mahjong_kinds(text),
    winning_tile: mahjong_kinds(winning).first, **context)
end

assert_equal(nil, mcr_score('123456m23455p678s', '8s'), 'An ordinary closed hand is below eight fan')
assert_equal(nil, mcr_score('123456m23455p678s', '8s', flowers: 8), 'Flowers cannot establish the eight-point minimum')
assert_equal(nil, mcr_score('123456m23455p678s', '8s', self_draw: true), 'Seven non-flower fan still cannot win')
last = mcr_score('123456m23455p678s', '8s', self_draw: true, flags: {last_draw: true})
assert_equal(15, last.fan)
assert(last.patterns.any? { |fan| fan.id == 44 })
assert(last.patterns.none? { |fan| fan.id == 80 }, 'Last draw includes the self-draw fan')
assert(last.patterns.none? { |fan| fan.id == 76 }, 'All Chows includes No Honors')

melds = [[:chow, 0, true], [:chow, 11, true], [:chow, 23, true]]
chicken = mcr_score('555m33z', '5m', melds: melds, flowers: 3)
assert_equal(8, chicken.fan)
assert_equal(3, chicken.flowers)
assert_equal([43], chicken.patterns.map(&:id))
assert_equal(nil, mcr_score('555m33z', '5m', melds: melds, self_draw: true), 'A one-point self draw is not a zero-fan Chicken Hand')
assert_equal(nil, mcr_score('555m33z', '5m', melds: melds, flags: {last_kind: true}, flowers: 4), 'Four base fan must not become Chicken Hand or qualify through flowers')

shifted = mcr_score('11223344556677m', '7m')
assert_equal(88, shifted.fan)
assert_equal(:seven_pairs, shifted.form.type, 'Choose the highest scoring interpretation, not the first standard decomposition')
assert_equal([6], shifted.patterns.map(&:id))
assert_equal(92, mcr_score('11223344556677m', '7m', self_draw: true).fan)

winds = mcr_score('11122233344455z', '5z')
assert_equal(217, winds.fan)
assert_equal([1, 11, 12, 79], winds.patterns.map(&:id))
assert(winds.patterns.none? { |fan| [18, 38, 49, 55, 60, 61, 62, 73].include?(fan.id) })
assert_equal(221, mcr_score('11122233344455z', '5z', self_draw: true).fan)
assert_equal(29, mcr_score('123456789m11155z', '5z').fan)
knitted_pair = mcr_score('147m258p369s123m11p', '1p')
assert_equal(17, knitted_pair.fan)
assert_equal(:pair, knitted_pair.wait)
assert(knitted_pair.patterns.any? { |fan| fan.id == 79 })
knitted_edge = mcr_score('147m258p369s123m99p', '3m')
assert_equal(17, knitted_edge.fan)
assert_equal(:edge, knitted_edge.wait)
assert(knitted_edge.patterns.any? { |fan| fan.id == 77 })
knitted_closed = mcr_score('147m258p369s234m99p', '3m')
assert_equal(17, knitted_closed.fan)
assert_equal(:closed, knitted_closed.wait)
assert(knitted_closed.patterns.any? { |fan| fan.id == 78 })
assert_equal(nil, mcr_score('123m456p789s12344z', '4z'))
assert(chicken.frozen? && chicken.patterns.frozen? && chicken.patterns.all?(&:frozen?))
assert_raises(ArgumentError) { mcr_score('123456m23455p678s', '8s', flowers: 9) }
assert_raises(ArgumentError) { mcr_score('123456m23455p678s', '8s', flags: {replacement: true}) }
puts 'PASS internal MCR scoring pipeline: WMO exclusion policy, best decomposition, eight non-flower threshold, Chicken Hand, immutable results and strict context; catalog release still pending audit'
