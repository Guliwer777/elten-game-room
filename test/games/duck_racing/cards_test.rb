require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/cards"

include GameRoomTest::Assertions
cards = GameRoomDuckRacing::Cards
assert_equal((1..11).to_a + (23..48).to_a, cards::TYPES.map(&:reference))
assert_equal(37, cards::BY_ID.size)
assert_equal(3, cards::INITIAL_HAND_SIZE)
assert_equal("Investment", cards::BY_ID.fetch("investment").english_name)
assert_equal("Golden sleep", cards::BY_ID.fetch("golden_sleep").english_name)

# Inspect the actual bound passed to rand. A finite deck or weighted list
# would shrink/change it; each independent draw must use the same 37 types.
class DuckCyclingRandom
  attr_reader :bounds
  def initialize
    @index, @bounds = 0, []
  end
  def rand(bound)
    @bounds << bound
    result = @index % bound
    @index += 1
    result
  end
end

random = DuckCyclingRandom.new
drawn = cards.draw(count: 111, next_serial: 1, random: random)
assert_equal(Array.new(111, 37), random.bounds)
assert_equal(cards::POOL * 3, drawn.cards.map(&:type))
assert_equal(111, drawn.cards.map(&:id).uniq.size)
assert_equal(112, drawn.next_serial)
assert_equal("duck-card-1", drawn.cards.first.id)
assert_equal("duck-card-111", drawn.cards.last.id)
assert_equal(cards::POOL.to_h { |type| [type, 3] }, drawn.cards.map(&:type).tally)
assert(drawn.frozen? && drawn.cards.frozen? && drawn.cards.all?(&:frozen?), "draw result is mutable")

repeated = cards.draw(count: 40, next_serial: 112, random: Random.new(3), eligible: ["mine", "mine"])
assert_equal(["mine"], repeated.cards.map(&:type).uniq)
assert_equal(40, repeated.cards.map(&:id).uniq.size)
assert_equal("duck-card-112", repeated.cards.first.id)
assert_equal(152, repeated.next_serial)

random = Random.new(804)
restored_random = Random.new(804)
first = cards.draw(count: 7, next_serial: 1, random: random)
second = cards.draw(count: 9, next_serial: first.next_serial, random: random)
replayed = cards.draw(count: 16, next_serial: 1, random: restored_random)
assert_equal(replayed.cards, first.cards + second.cards)
assert_equal(restored_random.rand(100_000), random.rand(100_000), "replay changed the next random result")

filtered = cards.draw(count: 50, next_serial: 1, random: Random.new(0), eligible: %w[investment mine])
assert_equal(%w[investment mine], filtered.cards.map(&:type).uniq.sort)
reordered = cards.draw(count: 50, next_serial: 1, random: Random.new(0), eligible: %w[mine investment investment])
assert_equal(filtered, reordered, "filter ordering or duplicate entries changed probabilities")
assert_raises(ArgumentError) { cards.draw(count: 1, next_serial: 1, random: Random.new(0), eligible: ["poisoned_gift"]) }
assert_raises(ArgumentError) { cards.draw(count: 1, next_serial: 1, random: Random.new(0), eligible: []) }
assert_raises(ArgumentError) { cards.draw(count: -1, next_serial: 1, random: Random.new(0)) }
assert_raises(ArgumentError) { cards.draw(count: 1, next_serial: 0, random: Random.new(0)) }
assert_raises(ArgumentError) { cards.draw(count: 1.0, next_serial: 1, random: Random.new(0)) }
assert_equal([], cards.draw(count: 0, next_serial: 99, random: Random.new(0), eligible: []).cards)
puts "PASS Duck Racing selected pool, unlimited draws, stable copies, filters and replay"
