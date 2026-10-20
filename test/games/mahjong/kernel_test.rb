require_relative '../../support/assertions'
require_relative '../../support/elten_array_shuffle'
require_relative '../../../games/mahjong_support/tiles'
require_relative '../../../games/mahjong_support/rules'
require_relative '../../../games/mahjong_support/hand'
require_relative '../../../games/mahjong_support/solitaire'
include GameRoomTest::Assertions

tiles = GameRoomMahjong::Tiles
rules = GameRoomMahjong::Rules
hand = GameRoomMahjong::Hand
solitaire = GameRoomMahjong::Solitaire

assert_equal(136, tiles.set.length)
assert_equal(144, tiles.set(bonuses: true).length)
assert_equal(108, tiles.set(sanma: true).length)
assert_equal(34, tiles.set.map { |tile| tiles.kind(tile) }.uniq.length)
assert(tiles.set(sanma: true).none? { |tile| tiles.kind(tile).between?(1, 7) })
assert(tiles.match?(0, 3))
assert(!tiles.match?(0, 0), 'One physical tile cannot be its own pair')
assert(tiles.match?(136, 139))
assert(tiles.match?(140, 143))
assert(!tiles.match?(139, 140), 'Flowers do not match seasons')
[-1, 144, '0', nil, true].each { |tile| assert_raises(ArgumentError) { tiles.kind(tile) } }

assert_equal([1], rules.allowed_seats('solitaire'))
assert_equal([3, 4], rules.allowed_seats('riichi'))
assert_equal(2, rules.missing_seats({'variant'=>'hong_kong'}, 2))
assert_equal(1, rules.missing_seats({'variant'=>'riichi', 'seats'=>3}, 2))
assert_raises(ArgumentError) { rules.normalize('variant'=>'mcr', 'seats'=>3) }
assert_raises(ArgumentError) { rules.normalize('variant'=>'unknown') }
assert_raises(ArgumentError) { rules.normalize('variant'=>'riichi', 'seats'=>3.0) }
assert_raises(ArgumentError) { rules.missing_seats({'variant'=>'solitaire'}, 2) }

standard = [0, 1, 2, 9, 10, 11, 18, 19, 20, 27, 27, 27, 33, 33]
assert_equal(1, hand.forms(standard).length)
assert_equal(:standard, hand.forms(standard).first.type)
assert_equal([33], hand.waits(standard[0...-1]))
ambiguous = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
assert(hand.forms(ambiguous).length > 1, 'Scoring needs all valid decompositions')
seven = (0...7).flat_map { |kind| [kind, kind] }
assert(hand.forms(seven).any? { |form| form.type == :seven_pairs })
assert(hand.forms(seven).any? { |form| form.type == :standard })
assert_equal([], hand.forms([0] * 4 + [3, 3, 5, 5, 9, 9, 15, 15, 27, 27]).select { |form| form.type == :seven_pairs })
assert(hand.forms([0] * 4 + [3, 3, 5, 5, 9, 9, 15, 15, 27, 27], split_quads: true).any? { |form| form.type == :seven_pairs })
assert_equal(:thirteen_orphans, hand.forms(tiles::ORPHANS + [33]).first.type)
assert_equal(tiles::ORPHANS, hand.waits(tiles::ORPHANS))
assert_equal([], hand.forms(tiles::ORPHANS))
assert_raises(ArgumentError) { hand.forms([0] * 5 + standard.first(9)) }
assert_raises(ArgumentError) { hand.forms(standard, melds: [[:chow, 8]]) }
assert_raises(ArgumentError) { hand.forms(standard, melds: [[:pung, 33]]) }
assert_equal(:standard, hand.forms([9, 10, 11, 18, 19, 20, 27, 27, 27, 33, 33], melds: [[:kong, 0]]).first.type)
puts 'PASS mahjong tile inventory, variant seat rules, winning decompositions and waits'

solitaire::LAYOUTS.each do |layout|
  [0, 1, 2, 37, 4096].each do |seed|
    deal = solitaire.deal(seed: seed, layout: layout)
    assert_equal(144, deal.game.remaining.length)
    assert_equal(144, deal.game.tiles.uniq.length)
    assert_equal(deal.game.tiles, solitaire.deal(seed: seed, layout: layout).game.tiles)
    current = deal.game
    deal.solution.each do |first, second|
      assert(current.free?(first) && current.free?(second), 'Generator supplied a blocked removal')
      assert(tiles.match?(current.tiles[first], current.tiles[second]))
      current = current.remove(first, second)
    end
    assert(current.finished?)
    assert(!current.blocked?)
    assert_equal(144, deal.game.remaining.length, 'Removing a pair mutated the previous snapshot')
    assert_raises(ArgumentError) { deal.game.remove(deal.solution[0][0], deal.solution[0][0]) }
  end
end

position = solitaire::Position
line = solitaire.new(positions: 3.times.map { |index| position.new(x: index * 2, y: 0, level: 0) } + [position.new(x: 0, y: 2, level: 0)], tiles: [0, 1, 2, 3])
assert(!line.free?(1), 'A tile blocked on both horizontal sides is not free')
assert(line.free?(0) && line.free?(2), 'One free horizontal side is enough')
stack = solitaire.new(positions: [position.new(x: 0, y: 0, level: 0), position.new(x: 1, y: 1, level: 1)], tiles: [0, 1])
assert(!stack.free?(0), 'A partially overlapping upper tile covers the tile below')
assert(stack.free?(1))
assert(!stack.free?('1'))
assert_raises(ArgumentError) { stack.remove(0, 1) }
blocked = solitaire.new(positions: [position.new(x: 0, y: 0, level: 0), position.new(x: 2, y: 0, level: 0)], tiles: [0, 4])
assert(blocked.blocked?)
puts 'PASS solitaire deterministic solvable layouts, geometric blocking, flower/season matching and immutable moves'
