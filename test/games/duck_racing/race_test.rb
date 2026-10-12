require_relative "../../support/assertions"
require_relative "../../../games/duck_racing_support/race"

include GameRoomTest::Assertions

module DuckRaceFixture
  module_function

  def state(count: 3, laps: 3, positions: nil, seed: 901)
    state = GameRoomDuckRacing::Race.start(player_count: count, laps: laps,
      seed: seed, enabled_challenges: ["dice_duel"])
    if positions
      state[:occupants] = {}
      positions.each_with_index do |progress, seat|
        state[:racers][seat][:progress] = progress
        GameRoomDuckRacing::Board.arrive!(state[:occupants], seat, GameRoomDuckRacing::Board.square(progress))
      end
    end
    state
  end

  def card(state, type, seat: 0)
    copy = GameRoomDuckRacing::Cards::Copy.new("fixture-#{seat}-#{type}", type)
    state[:racers][seat][:hand] << copy
    copy
  end

  def play(state, type, target: nil)
    copy = card(state, type)
    GameRoomDuckRacing::Race.new(state).apply(seat: 0, revision: state[:revision],
      action: {kind: :play, card: copy.id, target: target})
  end

  def settle(state, winner: nil, amount: 0)
    challenge = state.fetch(:challenge)
    balances = challenge[:participants].to_h { |seat| [seat, state[:racers][seat][:feathers]] }
    result = GameRoomDuckRacing::Settlement.fixed(balances: balances, winner: winner, amount: amount)
    GameRoomDuckRacing::Race.new(state).complete_challenge(id: challenge[:id], result: result)
  end
end

class DuckRaceRandom
  def initialize(*values); @values = values; end
  def rand(bound)
    value = @values.shift
    raise "Unexpected race RNG draw (#{bound})" unless value && value.between?(0, bound - 1)
    value
  end
end

f = DuckRaceFixture
s = f.state
assert_equal(18, s[:racers][0][:feathers])
assert_equal([3, 3, 3], s[:racers].values.map { |racer| racer[:hand].size })
assert_equal(9, s[:racers].values.flat_map { |racer| racer[:hand].map(&:id) }.uniq.size)
assert_equal([0, 1, 2], s[:occupants][1])
assert_raises(ArgumentError) { GameRoomDuckRacing::Race.start(player_count: 3, laps: 3, seed: 1, enabled_challenges: ["axel_pong"]) }

# Rejected commands change neither state nor the random generator.
copy = f.card(s, "mine")
s[:racers][0][:feathers] = 6
[
  [0, 0, {kind: :play, card: copy.id}], [0, 0, {kind: :play, card: "missing"}],
  [1, 0, {kind: :roll}], [0, 1, {kind: :roll}], [0.0, 0, {kind: :roll}],
  [0, 0.0, {kind: :roll}], [0, 0, {kind: :skip}], [0, 0, {kind: :unsupported}]
].each do |seat, revision, action|
  before = Marshal.dump(s)
  assert_equal(false, GameRoomDuckRacing::Race.new(s).apply(seat: seat, revision: revision, action: action))
  assert_equal(before, Marshal.dump(s))
end

# Backward movement crosses lap boundaries and only stops at the initial start.
s = f.state(positions: [31, 8, 12])
assert(f.play(s, "tiny_recoil"))
assert_equal(29, s[:racers][0][:progress])
assert_equal(21, s[:racers][0][:feathers], "card reward and square 30 reward must both apply")
assert_equal(0, s[:turn])
before = Marshal.dump(s)
assert_equal(false, GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: 0, action: {kind: :roll}))
assert_equal(before, Marshal.dump(s))
s = f.state(positions: [1, 8, 12])
assert(f.play(s, "tiny_recoil"))
assert_equal(0, s[:racers][0][:progress])
assert_equal(21, s[:racers][0][:feathers])
s = f.state(positions: [0, 8, 12])
assert(f.play(s, "tiny_recoil"))
assert_equal(20, s[:racers][0][:feathers], "no movement must not re-trigger the start square")

# A card can finish immediately, without landing bonuses or a later duel.
s = f.state(positions: [88, 8, 12])
assert(f.play(s, "helix", target: 0))
assert_equal(:finished, s[:phase])
assert_equal(0, s[:winner])
assert_equal(92, s[:racers][0][:progress])
assert_equal([], s[:pending])
assert_equal(11, s[:racers][0][:feathers])
assert_equal(false, GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: s[:revision], action: {kind: :roll}))

# Every selected card has a handled effect and is removed before transfers.
GameRoomDuckRacing::Cards::TYPES.each do |type|
  s = f.state(positions: [8, 22, 26])
  s[:racers][0][:feathers] = 100
  original_ids = s[:racers].values.flat_map { |racer| racer[:hand].map(&:id) }
  target = [:opponent, :any].include?(type.target) ? 1 : nil
  assert(f.play(s, type.id, target: target), "cannot play selected #{type.id}")
  ids = s[:racers].values.flat_map { |racer| racer[:hand].map(&:id) }
  assert_equal(ids.size, ids.uniq.size, "duplicated physical card after #{type.id}")
  assert(!ids.include?("fixture-0-#{type.id}"), "played card returned to a hand after #{type.id}")
  assert_equal(100 - type.cost + type.gain, s[:racers][0][:feathers]) if type.target == :square
end

# Card grants must be audible before later square/skip effects.
%w[investment sandwich repairing_rest tiny_recoil altruism].each do |id|
  s = f.state(positions: [10, 20, 25])
  type = GameRoomDuckRacing::Cards::BY_ID.fetch(id)
  assert(f.play(s, id))
  played = s[:notices].index { |entry| entry[0] == (type.target == :square ? :placed : :played) }
  assert_equal([:feathers, 0, type.gain], s[:notices][played + 1], "Missing immediate gain for #{id}")
  assert_equal(1, s[:notices].count { |entry| entry == [:feathers, 0, type.gain] }, "Repeated gain for #{id}")
end

# Switching and rotating hands retain exact physical copies and actual order.
s = f.state
hands = s[:racers].transform_values { |racer| racer[:hand].dup }
assert(f.play(s, "hand_switch", target: 1))
assert_equal(hands[1], s[:racers][0][:hand])
assert_equal(hands[0], s[:racers][1][:hand])
assert_equal(hands[2], s[:racers][2][:hand])
assert_equal([1, 1, 0], s[:racers].values.map { |racer| racer[:hand_epoch] })
s = f.state
hands = s[:racers].transform_values { |racer| racer[:hand].dup }
assert(f.play(s, "hand_mix"))
assert_equal([hands[2], hands[0], hands[1]], s[:racers].values.map { |racer| racer[:hand] })

# A pre-roll skip consumes this turn; freeze and skip decrease concurrently.
s = f.state
assert(f.play(s, "sandwich"))
assert_equal(21, s[:racers][0][:feathers])
assert_equal(0, s[:turn])
assert_equal(false, GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: s[:revision], action: {kind: :roll}))
assert(GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: s[:revision], action: {kind: :skip}))
assert_equal(1, s[:turn])
assert_equal(0, s[:racers][0][:skip_turns])
s = f.state
s[:racers][0].merge!(feathers: 0, frozen_turns: 1, skip_turns: 2, die_sides: 10, die_rolls: 2)
hand = s[:racers][0][:hand].dup
assert(GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: 0, action: {kind: :skip}))
assert_equal([5, 0, 1, 2, hand], s[:racers][0].values_at(:feathers, :frozen_turns, :skip_turns, :die_rolls, :hand))

# The freeze is checked after a complete effect, not before its compensation.
s = f.state
s[:racers][1][:feathers] = 0
assert(f.play(s, "golden_sleep", target: 1))
assert_equal([6, 2, 0], s[:racers][1].values_at(:feathers, :skip_turns, :frozen_turns))

# Encounter across laps: latest eligible occupant, ignoring frozen ducks.
s = f.state(count: 4, positions: [30, 31, 1, 1])
s[:racers][3][:frozen_turns] = 2
s[:random] = DuckRaceRandom.new(0, 0, 34)
assert(GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: 0, action: {kind: :roll}))
assert_equal(:challenge, s[:phase])
assert_equal([2, 0], s[:challenge][:participants])
assert_equal(21, s[:racers][0][:feathers], "square reward must precede encounter")
challenge_id = s[:challenge][:id]
assert(f.settle(s, winner: 2, amount: 100))
assert_equal(0, s[:racers][0][:feathers])
assert_equal(4, s[:racers][0][:frozen_turns])
assert_equal(1, s[:turn])
before = Marshal.dump(s)
assert_equal(false, GameRoomDuckRacing::Race.new(s).complete_challenge(id: challenge_id,
  result: GameRoomDuckRacing::Settlement.fixed(balances: {0 => 0, 2 => 39}, winner: 2, amount: 5)))
assert_equal(before, Marshal.dump(s))

# Questions include frozen players, then resume the same pending turn.
s = f.state
s[:racers][1].merge!(feathers: 0, frozen_turns: 2)
assert(f.play(s, "curiosity"))
assert_equal([0, 1, 2], s[:challenge][:participants])
assert_equal("quiz", s[:challenge][:kind])
balances = s[:racers].transform_values { |racer| racer[:feathers] }
result = GameRoomDuckRacing::Settlement.quiz(balances: balances, answers: {0 => true, 1 => true, 2 => false})
assert(GameRoomDuckRacing::Race.new(s).complete_challenge(id: s[:challenge][:id], result: result))
assert_equal([4, 2], s[:racers][1].values_at(:feathers, :frozen_turns))
assert_equal(0, s[:turn])
assert(s[:card_played])

# A moving trap sends the duck to its new square and cancels the stale duel.
s = f.state(count: 2, positions: [8, 5])
trap_card = GameRoomDuckRacing::Cards::Copy.new("placed-mine", "mine")
s[:traps][9] = {card: trap_card, owner: 0}
s[:turn] = 1
s[:random] = DuckRaceRandom.new(2)
assert(GameRoomDuckRacing::Race.new(s).apply(seat: 1, revision: 0, action: {kind: :roll}))
assert_equal(0, s[:racers][1][:progress])
assert_equal(19, s[:racers][1][:feathers])
assert_equal(:turn, s[:phase])
assert_equal(nil, s[:challenge])
assert_equal({}, s[:traps])
assert_equal([1], s[:occupants][1])
assert_equal([0], s[:occupants][9])

# Serializing a pending challenge keeps its exact continuation and future RNG.
s = f.state
assert(f.play(s, "challenge", target: 1))
restored = Marshal.load(Marshal.dump(s))
assert(f.settle(s, winner: 0, amount: 3))
assert(f.settle(restored, winner: 0, amount: 3))
assert_equal(Marshal.dump(s), Marshal.dump(restored))
assert(GameRoomDuckRacing::Race.new(s).apply(seat: 0, revision: s[:revision], action: {kind: :roll}))
assert(GameRoomDuckRacing::Race.new(restored).apply(seat: 0, revision: restored[:revision], action: {kind: :roll}))
assert_equal(Marshal.dump(s), Marshal.dump(restored))
puts "PASS Duck Racing turn reducer, 37 cards, movement, freeze, encounters, effects, settlement and restoration"
