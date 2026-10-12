require_relative "../../support/assertions"
require_relative "../../../games/duck_racing_support/board"
require_relative "../../../games/duck_racing_support/challenges"

include GameRoomTest::Assertions
board = GameRoomDuckRacing::Board
challenges = GameRoomDuckRacing::Challenges
assert_equal((1..30).to_a, board::SQUARES.keys)
[-61, -31, -1, 29, 59, 89].each { |progress| assert_equal(30, board.square(progress)) }
[-60, -30, 0, 30, 60].each { |progress| assert_equal(1, board.square(progress)) }
assert_raises(ArgumentError) { board.square(0.1) }
assert_equal(board::Move.new(29, 30, 1, false), board.advance(30, by: -1, laps: 3))
assert_equal(board::Move.new(5, 6, 1, false), board.advance(75, by: -70, laps: 3))
assert_equal(board::Move.new(0, 1, 1, false), board.advance(75, by: -100, laps: 3))
assert_equal(board::Move.new(89, 30, 3, false), board.advance(88, by: 1, laps: 3))
assert_equal(true, board.advance(89, by: 1, laps: 3).finished)
assert_equal(true, board.advance(89, by: 15, laps: 3).finished)
assert_raises(ArgumentError) { board.advance(-1, by: 1, laps: 3) }
assert_raises(ArgumentError) { board.advance(90, by: -1, laps: 3) }

class DuckChanceRandom
  attr_reader :values, :calls
  def initialize(values)
    @values, @calls = values.dup, []
  end
  def rand(bound)
    @calls << bound
    @values.shift || raise("unexpected random draw")
  end
end

# Every possible combination of the three independent checks, including the
# 59/60 boundary. None of the other squares performs a probability draw.
8.times do |mask|
  values = 3.times.map { |bit| mask[bit] == 1 ? 59 : 60 }
  random = DuckChanceRandom.new(values)
  effects = board.landing(19, random: random)
  expected = [[:feathers, 1], [:cards, 1], [:skip, 1]].each_with_index.filter_map { |effect, bit| effect if mask[bit] == 1 }
  assert_equal(expected, effects)
  assert_equal([100, 100, 100], random.calls)
  assert_equal([], random.values)
end
board::SQUARES.each do |square, effects|
  next if square == 19
  random = DuckChanceRandom.new([])
  assert_equal(effects, board.landing(square, random: random))
  assert_equal([], random.calls)
  assert(effects.frozen? && effects.all?(&:frozen?))
end
assert_raises(KeyError) { board.landing(31, random: Random.new(0)) }

occupants = {}
assert_equal(nil, board.arrive!(occupants, "A", 5))
assert_equal("A", board.arrive!(occupants, "B", 5))
assert_equal("B", board.arrive!(occupants, "C", 5))
assert_equal("C", board.arrive!(occupants, "D", 5))
assert_equal(%w[A B C D], occupants[5])
board.leave!(occupants, "D")
assert_equal("C", board.arrive!(occupants, "A", 5), "departure or earlier occupant defeated arrival order")
assert_equal(%w[B C A], occupants[5])
assert_equal(nil, board.arrive!(occupants, "C", 8))
assert_equal(%w[B A], occupants[5])
assert_equal(["C"], occupants[8])
restored = Marshal.load(Marshal.dump(occupants))
assert_equal("C", board.arrive!(restored, "A", 8))
assert_equal(["B"], restored[5])
assert_equal(%w[C A], restored[8])
before = Marshal.dump(occupants)
assert_raises(ArgumentError) { board.arrive!(occupants, "B", 31) }
assert_equal(before, Marshal.dump(occupants), "rejected arrival changed occupancy")

assert_equal(18, challenges::TYPES.size)
assert_equal([1, 2, 3, 4, 6, 7, 8, 9, 19, 22, 24, 25, 26, 27, 28], challenges::TYPES.map(&:reference).compact)
ids = challenges::TYPES.map(&:id)
assert_equal(ids, challenges.eligible(player_count: 2, enabled: ids).map(&:id))
(3..8).each do |count|
  available = challenges.eligible(player_count: count, enabled: ids).map(&:id)
  assert_equal(13, available.size)
  assert_equal([], available & %w[rock_paper_scissors numbered_balls sound_memory audio_ball axel_pong])
end
assert_equal([], challenges.eligible(player_count: 2, enabled: []))
assert_equal(["dice_duel"], challenges.eligible(player_count: 2, enabled: ["dice_duel"]).map(&:id))
assert_raises(ArgumentError) { challenges.eligible(player_count: 9, enabled: ids) }
assert_raises(ArgumentError) { challenges.eligible(player_count: 2, enabled: ["roulette"]) }
puts "PASS Duck Racing 30 squares, independent chances, arrival order, restores and challenge eligibility"
