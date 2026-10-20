require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/mcr_combination'
require_relative '../../support/mahjong_tiles'
include GameRoomTest::Assertions
include MahjongTestTiles

def fan(id, sets = nil)
  GameRoomMahjong::MCRPatterns::Candidate.new(id: id, points: GameRoomMahjong::MCRPatterns::POINTS.fetch(id - 1), sets: sets)
end
solver = GameRoomMahjong::MCRCombination
chosen = solver.select([fan(22), fan(76), fan(63)], exclusions: {22=>[76], 63=>[76]})
assert_equal([22, 63], chosen.map(&:id))
assert_equal(26, chosen.sum(&:points))

# An existing pure straight's component chows cannot score a second fan
# together; the fourth chow may attach to one of them only once.
straight = fan(28, [0, 1, 2])
inside = fan(71, [0, 1])
pair_a = fan(69, [0, 3])
pair_b = fan(71, [1, 3])
chosen = solver.select([straight, inside, pair_a, pair_b], exclusions: {})
assert_equal(17, chosen.sum(&:points))
assert_equal(2, chosen.length)

# Three chows cannot manufacture three pairwise Mixed Double Chows.
triangle = [[0, 1], [1, 2], [0, 2]].map { |sets| fan(70, sets) }
assert_equal(1, solver.select(triangle, exclusions: {}).length, 'Non-identical: a group cannot repeat the same fan with another group')
disjoint = [fan(69, [0, 1]), fan(69, [2, 3]), fan(70, [0, 2])]
assert_equal(3, solver.select(disjoint, exclusions: {}).length, 'Two independent pure pairs and one connecting mixed pair can form a forest')

# The same wind pung may earn both seat and prevalent wind facts.
assert_equal(4, solver.select([fan(60, [0]), fan(61, [0])], exclusions: {}).sum(&:points))
assert_equal([1], solver.select([fan(1), fan(38), fan(49), fan(60, [0])], exclusions: {1=>[38, 49, 60]}).map(&:id))
assert_equal(24, solver.select([fan(22), fan(22)], exclusions: {}).sum(&:points))
assert_equal(4, solver.select([fan(64), fan(64)], exclusions: {}).sum(&:points), 'Distinct physical Tile Hogs remain separately countable')
chosen = solver.select([fan(28, [0, 1, 2]), fan(69, [0, 3])], exclusions: {})
assert(chosen.frozen? && chosen.all?(&:frozen?) && chosen.all? { |entry| entry.sets.frozen? })
assert_raises(ArgumentError) { solver.select([fan(81)], exclusions: {}) }
assert_raises(ArgumentError) { solver.select([fan(69, [0, 0])], exclusions: {}) }
concealed = mahjong_kinds('111222333z999m44z')
form = GameRoomMahjong::MCRShapes.forms(concealed).find { |candidate| candidate.type == :standard }
detected = GameRoomMahjong::MCRPatterns.candidates(concealed: concealed,
  winning_tile: 30, form: form, wait: :pair)
relevant = detected.select { |candidate| [9, 38, 60, 61, 73].include?(candidate.id) }
selected = solver.select(relevant, exclusions: {9=>[38]}, scoped_exclusions: {9=>[73]})
assert_equal(69, selected.sum(&:points), 'The supplied scoped rule must not remove unrelated sets; this subset omits other fan and is not a final hand score')
terminal = selected.select { |candidate| candidate.id == 73 }
assert_equal(1, terminal.length)
assert_equal(8, form.groups.fetch(terminal.first.sets.first).last)
assert(selected.find { |candidate| candidate.id == 9 }.scope.frozen?)
assert_raises(ArgumentError) { solver.select([fan(9), fan(73, [0])], exclusions: {}, scoped_exclusions: {9=>[73]}) }
puts 'PASS internal MCR combination optimizer: explicit exclusions, group non-reuse, account-once forest, distinct repeated patterns, wind facts and immutable selection; not a final scoring policy'
