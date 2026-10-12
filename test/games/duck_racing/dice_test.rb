require_relative "../../support/assertions"
require_relative "../../../games/duck_racing_support/dice"

include GameRoomTest::Assertions
dice = GameRoomDuckRacing::Dice
racer = {die_sides: 6, die_rolls: 0}
random = Random.new(781)
[3, 10, 12].each do |sides|
  dice.change!(racer, sides: sides, rolls: 2)
  100.times do
    assert(dice.roll!(racer, random: random, count: 2).all? { |value| value.between?(1, sides) })
    assert_equal({die_sides: sides, die_rolls: 2}, racer)
  end
  dice.roll!(racer, random: random, race: true)
  assert_equal({die_sides: sides, die_rolls: 1}, racer)
  assert(dice.roll!(racer, random: random, race: true).first.between?(1, sides))
  assert_equal({die_sides: 6, die_rolls: 0}, racer)
  assert(dice.roll!(racer, random: random, race: true).first.between?(1, 6))
end
dice.change!(racer, sides: 3, rolls: 2)
dice.change!(racer, sides: 12, rolls: 3)
assert_equal({die_sides: 12, die_rolls: 3}, racer)
dice.change!(racer, sides: 6, rolls: 0)
before = Marshal.dump(racer)
[[4, 2], [6, 1], [3, 0], [12, -1]].each do |sides, rolls|
  assert_raises(ArgumentError) { dice.change!(racer, sides: sides, rolls: rolls) }
  assert_equal(before, Marshal.dump(racer))
end
generator_before = Marshal.dump(random)
assert_raises(ArgumentError) { dice.roll!(racer, random: random, count: 2, race: true) }
assert_equal(generator_before, Marshal.dump(random))
puts "PASS Duck Racing dice modifiers: challenge reuse, race consumption, replacement and validation"
