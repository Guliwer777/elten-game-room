require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../../games/mahjong_support/mcr_shapes'
include GameRoomTest::Assertions
include MahjongTestTiles
shapes = GameRoomMahjong::MCRShapes

greater = mahjong_kinds('147m258p3s1234567z')
assert_equal([:greater_knitted], shapes.forms(greater).map(&:type))
lesser = mahjong_kinds('147m258p369s12345z')
assert(shapes.forms(lesser).any? { |form| form.type == :lesser_knitted })
assert_equal([], shapes.forms(mahjong_kinds('147m147p369s12345z')), 'Two suits cannot use the same knitted sequence')
straight = mahjong_kinds('147m258p369s11122z')
form = shapes.forms(straight).find { |candidate| candidate.type == :knitted_straight }
assert(form)
assert_equal(28, form.pair)
assert_equal([[:pung, 27]], form.groups)
exposed = mahjong_kinds('147m258p369s22z')
assert(shapes.forms(exposed, melds: [[:kong, 27]]).any? { |candidate| candidate.type == :knitted_straight })
assert_equal([28], shapes.waits(mahjong_kinds('147m258p369s2z'), melds: [[:pung, 27]]))
assert_equal([], shapes.forms(mahjong_kinds('147m258p369s12223z')))
ordinary = mahjong_kinds('123m456p789s11122z')
assert(shapes.forms(ordinary).any? { |candidate| candidate.type == :standard })
seven = mahjong_kinds('111122m33p44p55s66s')
assert(shapes.forms(seven).any? { |candidate| candidate.type == :seven_pairs }, 'MCR permits a quad to count as two pairs')
assert_equal([], shapes.forms(greater[0...-1]))
assert_raises(ArgumentError) { shapes.forms(mahjong_kinds('11111m234p567s111z')) }
puts 'PASS MCR hand shapes: standard, quad-containing seven pairs, greater/lesser knitted honors and knitted straight'
