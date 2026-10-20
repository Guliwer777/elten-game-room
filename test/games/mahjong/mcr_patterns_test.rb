require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../../games/mahjong_support/mcr_patterns'
include GameRoomTest::Assertions
include MahjongTestTiles

def candidates(text, winning, melds: [], **context, &form_filter)
  concealed = mahjong_kinds(text)
  forms = GameRoomMahjong::MCRShapes.forms(concealed, melds: melds.map { |meld| meld.first(2) })
  form = form_filter ? forms.find(&form_filter) : forms.first
  raise 'Invalid MCR pattern test hand' unless form
  GameRoomMahjong::MCRPatterns.candidates(concealed: concealed, winning_tile: mahjong_kinds(winning).first,
    melds: melds, form: form, **context)
end

assert_equal(81, GameRoomMahjong::MCRPatterns::POINTS.length)
found = candidates('222444m44666p888s', '4p')
assert(found.any? { |fan| fan.id == 21 && fan.points == 24 })
assert(found.any? { |fan| fan.id == 68 && fan.points == 2 })
found = candidates('444555666m444p55s', '5s')
assert(found.any? { |fan| fan.id == 26 && fan.points == 24 })
found = candidates('123123123m789p55s', '5s') { |form| form.groups.count { |kind, _tile| kind == :chow } == 4 }
assert(found.any? { |fan| fan.id == 23 && fan.points == 24 })
assert(!found.any? { |fan| fan.id == 14 })
found = candidates('222m333p44455s111z', '5s')
assert(found.any? { |fan| fan.id == 42 && fan.points == 8 })
found = candidates('147m258p369s12345z', '5z')
assert(found.any? { |fan| fan.id == 34 && fan.points == 12 })
assert(found.any? { |fan| fan.id == 35 && fan.points == 12 })
found = candidates('147m258p3s1234567z', '7z')
assert(found.any? { |fan| fan.id == 20 && fan.points == 24 })
assert(!found.any? { |fan| fan.id == 34 })
found = candidates('123m456p77s', '7s', melds: [[:kong, 27, true], [:kong, 31, false]])
assert(found.any? { |fan| fan.id == 57 && fan.points == 6 })
assert(found.any? { |fan| fan.id == 67 && fan.sets == [1] })
assert(found.any? { |fan| fan.id == 74 && fan.sets == [0] })
found = candidates('11122233344455z', '5z', wait: :pair)
assert(found.any? { |fan| fan.id == 1 && fan.points == 88 })
assert(found.any? { |fan| fan.id == 11 && fan.points == 64 })
assert(found.all?(&:frozen?))
found = candidates('147m258p369s123m55p', '5p') { |form| form.type == :knitted_straight }
assert(found.any? { |fan| fan.id == 35 })
assert(found.any? { |fan| fan.id == 63 }, 'Knitted Straight plus one chow and a suited pair may add All Chows')
found = candidates('147m258p369s123m55z', '5z') { |form| form.type == :knitted_straight }
assert(!found.any? { |fan| fan.id == 63 }, 'An honor pair prevents All Chows')
found = candidates('147m258p369s111m55p', '5p') { |form| form.type == :knitted_straight }
assert(!found.any? { |fan| fan.id == 63 }, 'A normal pung with the knitted tiles is not All Chows')
found = candidates('147m258p369s55p', '5p', melds: [[:chow, 0, true]]) { |form| form.type == :knitted_straight }
assert(found.any? { |fan| fan.id == 63 }, 'The fourth chow may be exposed')
assert_raises(ArgumentError) { candidates('123456m23455p678s', '8s', flags: {replacement: true}) }
assert_raises(ArgumentError) { candidates('123456m23455p678s', '8s', self_draw: true, flags: {robbing_kong: true}) }
assert_raises(ArgumentError) do
  concealed = mahjong_kinds('123456m23455p678s')
  form = GameRoomMahjong::MCRShapes.forms(concealed).first
  GameRoomMahjong::MCRPatterns.candidates(concealed: concealed, winning_tile: 25.0, form: form)
end
puts 'PASS MCR fan candidate detection: point grades, knitted All Chows, scoped winds, shifted sets, kong exposure and strict win context; final combination policy pending'
