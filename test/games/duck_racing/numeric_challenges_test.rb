require "json"
require "fileutils"
require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/numeric_challenges"

module DuckNumericTest
  extend GameRoomTest::Assertions
  ENGINE = GameRoomDuckRacing::NumericChallenges
  UNSET = Object.new.freeze

  class DieSequence
    def initialize(values)
      @values = values.dup
    end

    def rand(bound)
      value = @values.shift
      raise "Unexpected or out-of-bounds random draw" unless value && value.between?(0, bound - 1)
      value
    end
  end

  class << self
    attr_reader :results

    def test(name)
      @results ||= []
      return if case_filter && !case_filter.match?(name)

      yield
      @results << {name: name, status: "PASS"}
      puts "PASS #{name}"
    rescue StandardError => error
      @results << {name: name, status: "FAIL", error: "#{error.class}: #{error.message}", trace: error.backtrace.first(6)}
      warn "FAIL #{name}: #{error.class}: #{error.message}"
    end

    def case_filter
      @case_filter ||= Regexp.new(ENV.fetch("DUCK_NUMERIC_CASE")) if ENV.key?("DUCK_NUMERIC_CASE")
    end

    def start(type, **options)
      defaults = {seats: [0, 1], seed: 12_345, now_ms: 0}
      if options[:blackjack_decks]
        options[:blackjack_decks] = options[:blackjack_decks].transform_values do |ranks|
          available = ENGINE::BLACKJACK_CARDS.dup
          prefix = ranks.map do |rank|
            card = available.find { |id| id / 4 + 1 == rank }
            raise "Invalid test deck rank" unless card
            available.delete(card)
            card
          end
          prefix + available
        end
      end
      ENGINE.start(type, **defaults.merge(options))
    end

    def submit(state, seat, kind, value = UNSET, now: 1, id: nil, **extras)
      input = {kind: kind, press_id: id || state[:players].fetch(seat)[:last_press_id] + 1}
      input[:value] = value unless value.equal?(UNSET)
      ENGINE.submit(state, seat: seat, action: input.merge(extras), now_ms: now)
    end

    def rejected_unchanged(state)
      before = Marshal.dump(state)
      assert_equal(false, yield)
      assert_equal(before, Marshal.dump(state), "rejected input changed state or random stream")
    end

    def dice_sequence(state, seat, *faces)
      state[:players].fetch(seat)[:random] = DieSequence.new(faces.map { |face| face - 1 })
    end

    def finish_by_timeout(state)
      20.times do
        break if state[:finished]
        assert(ENGINE.expire(state, now_ms: state[:deadline_ms]))
      end
      assert(state[:finished])
    end

    def turn_order(state)
      return [] if state[:finished]
      state[:participants].rotate(state[:turn_index]).reject { |seat| state[:players].fetch(seat)[:done] }
    end
  end
end

T = DuckNumericTest
E = T::ENGINE

T.test("setup validates challenge, seats, seed, time and dice without hidden defaults") do
  T.assert_equal(9, E::TYPES.size)
  T.assert_equal(%w[dice_duel blackjack risky_dice numbered_balls], E::TURN_TYPES)
  ["roulette", nil, 2].each { |type| T.assert_raises(ArgumentError) { T.start(type) } }
  [[0], [0, 0], [0, -1], ["0", 1], (0..8).to_a].each do |seats|
    T.assert_raises(ArgumentError) { T.start("dice_duel", seats: seats) }
  end
  T.assert_raises(ArgumentError) { T.start("rock_paper_scissors", seats: [0, 1, 2]) }
  T.assert_raises(ArgumentError) { T.start("numbered_balls", seats: [0, 1, 2]) }
  [-1, "17", 17.0, nil].each { |seed| T.assert_raises(ArgumentError) { T.start("dice_duel", seed: seed) } }
  [-1, 0.1, "0"].each { |time| T.assert_raises(ArgumentError) { T.start("dice_duel", now_ms: time) } }
  [false, {0 => nil}, {4 => {die_sides: 6, die_rolls: 0}},
    {0 => {die_sides: 4, die_rolls: 1}}, {0 => {die_sides: 10, die_rolls: 0}}].each do |dice|
    T.assert_raises(ArgumentError) { T.start("dice_duel", dice: dice) }
  end
  T.assert_equal(50, T.start("blackjack")[:players][0][:deck].length)
  T.assert_raises(ArgumentError) { T.start("blackjack", blackjack_decks: {0 => [1, 13]}) }
end

T.test("invalid input, duplicate presses, repeats and deadline boundaries preserve exact state") do
  state = T.start("risky_dice", now_ms: 10)
  invalid = [nil, [], {}, {kind: :roll}, {kind: :roll, press_id: 0},
    {kind: :roll, press_id: 1, repeat: true}, {kind: :roll, press_id: 1, repeat: nil},
    {kind: :roll, press_id: 1, value: 4}, {kind: :roll, press_id: 1, extra: true},
    {kind: :roll, "kind" => "save", press_id: 1}, {kind: :save, press_id: 1}]
  invalid.each do |input|
    T.rejected_unchanged(state) { E.submit(state, seat: 0, action: input, now_ms: 10) }
  end
  [-1, 9, 30_010, 30_011, 10.1, "10"].each do |time|
    T.rejected_unchanged(state) { E.submit(state, seat: 0, action: {kind: :roll, press_id: 1}, now_ms: time) }
  end
  T.rejected_unchanged(state) { E.submit(state, seat: 99, action: {kind: :roll, press_id: 1}, now_ms: 11) }
  T.dice_sequence(state, 0, 1, 1, 2, 2)
  T.assert(E.submit(state, seat: 0, action: {"kind" => "roll", "press_id" => 3, "repeat" => false}, now_ms: 20))
  [1, 2, 3].each { |id| T.rejected_unchanged(state) { T.submit(state, 0, :roll, now: 21, id: id) } }
  T.rejected_unchanged(state) { T.submit(state, 1, :roll, now: 20) }
  [1, 2, 3].each { |id| T.rejected_unchanged(state) { T.submit(state, 0, :roll, now: 21, id: id) } }
  T.rejected_unchanged(state) { T.submit(state, 0, :roll, now: 19, id: 4) }
  T.assert(T.submit(state, 0, :roll, now: 20, id: 4))
  T.assert_equal([[1, 1], [2, 2]], state[:players][0][:rolls])
end

T.test("all nine RPS pairs, ties, copied input and missing-choice policy") do
  E::CHOICES.product(E::CHOICES).each do |left, right|
    state = T.start("rock_paper_scissors")
    choice = left.dup
    T.assert(T.submit(state, 0, :choose, choice))
    choice.replace("changed externally")
    T.assert_equal(left, state[:players][0][:choice])
    T.assert(T.submit(state, 1, :choose, right))
    difference = (E::CHOICES.index(left) - E::CHOICES.index(right)) % 3
    T.assert_equal(difference.zero? ? nil : (difference == 1 ? 0 : 1), state[:outcome][:winner])
    T.assert_equal(3, state[:outcome][:amount])
    T.assert(state[:outcome][:settlement_ready])
  end
  [0, 1].product(E::CHOICES).each do |seat, choice|
    state = T.start("rock_paper_scissors")
    T.assert(T.submit(state, seat, :choose, choice, now: 14_999))
    T.assert_equal(false, state[:finished])
    T.rejected_unchanged(state) { T.submit(state, 1 - seat, :choose, "rock", now: 15_000) }
    T.finish_by_timeout(state)
    T.assert_equal(seat, state[:outcome][:winner])
    T.assert_equal(3, state[:outcome][:amount])
    T.assert(state[:outcome][:settlement_ready])
    T.assert_equal([], state[:outcome][:unresolved])
    T.rejected_unchanged(state) { T.submit(state, 1 - seat, :choose, "paper", now: 15_001) }
    T.rejected_unchanged(state) { E.expire(state, now_ms: 15_001) }
  end
  empty = T.start("rock_paper_scissors")
  T.finish_by_timeout(empty)
  T.assert_equal(nil, empty[:outcome][:winner])
  T.assert(empty[:outcome][:settlement_ready])
end

T.test("private projections hide choices, random generators and opponents' inputs until completion") do
  state = T.start("rock_paper_scissors")
  T.assert(T.submit(state, 0, :choose, "paper"))
  observer = E.public_view(state, viewer: nil)
  opponent = E.public_view(state, viewer: 1)
  T.assert_equal({0 => true, 1 => false}, observer[:ready])
  T.assert(!observer.key?(:own) && !observer.key?(:results) && !observer.key?(:scores))
  T.assert_equal(nil, opponent[:own][:choice])
  T.assert(!Marshal.dump(observer).include?("Random"))
  mine = E.public_view(state, viewer: 0)
  T.assert_equal("paper", mine[:own][:choice])
  mine[:own][:choice].replace("rock")
  mine[:participants] << 999
  T.assert_equal("paper", state[:players][0][:choice])
  T.assert_equal([0, 1], state[:participants])
  T.assert(T.submit(state, 1, :choose, "scissors"))
  T.assert_equal("paper", E.public_view(state, viewer: nil)[:results][0][:choice])
end

T.test("dice modifiers are snapshots, never consumed by manual or automatic rolls") do
  source = {0 => {die_sides: 3, die_rolls: 1}, 1 => {die_sides: 12, die_rolls: 3}}
  before = Marshal.dump(source)
  state = T.start("dice_duel", dice: source)
  source[0][:die_sides] = 10
  T.dice_sequence(state, 0, 3)
  T.dice_sequence(state, 1, 12)
  T.assert(T.submit(state, 0, :roll, now: 9_999))
  T.assert_equal(19_999, state[:deadline_ms])
  T.rejected_unchanged(state) { T.submit(state, 1, :roll, now: 19_999) }
  T.finish_by_timeout(state)
  T.assert_equal({0 => 3, 1 => 12}, state[:scores])
  T.assert_equal(1, state[:outcome][:winner])
  T.assert_equal(Marshal.load(before), state[:dice])
  saved = Marshal.dump(state)
  T.assert_equal(false, E.expire(state, now_ms: 100_000))
  T.assert_equal(saved, Marshal.dump(state))
  T.rejected_unchanged(state) { T.submit(state, 0, :roll, now: 10_001) }
end

T.test("dice seat streams are independent of participant order and accept eight participants") do
  left = T.start("dice_duel", seats: (0..7).to_a)
  right = T.start("dice_duel", seats: (0..7).to_a.reverse)
  T.turn_order(left).each { |seat| T.assert(T.submit(left, seat, :roll, now: 100)) }
  T.turn_order(right).each { |seat| T.assert(T.submit(right, seat, :roll, now: 100)) }
  T.assert_equal(left[:scores], right[:scores])
  T.assert_equal(Marshal.dump(left[:players].sort.to_h), Marshal.dump(right[:players].sort.to_h))
  T.assert(left[:scores].values.all? { |score| score.between?(1, 6) })
end

T.test("equal highest dice scores are a group tie, not transfers from lower players") do
  state = T.start("dice_duel", seats: [0, 1, 2])
  [6, 6, 1].each_with_index { |score, seat| T.dice_sequence(state, seat, score) }
  T.finish_by_timeout(state)
  T.assert_equal(nil, state[:outcome][:winner])
  T.assert_equal([0, 1], state[:outcome][:tied])
  T.assert_equal({0 => 6, 1 => 6, 2 => 1}, state[:scores])
end

T.test("blackjack prepared decks, initial totals, face cards and ace choice on draw") do
  decks = {0 => [1, 1, 9, 13, 2], 1 => [12, 9, 2]}
  source = Marshal.dump(decks)
  state = T.start("blackjack", blackjack_decks: decks)
  T.assert_equal(12, state[:players][0][:total])
  T.assert_equal(19, state[:players][1][:total])
  T.assert(T.submit(state, 0, :hit))
  T.assert_equal(21, state[:players][0][:total])
  T.assert(state[:players][0][:done])
  T.rejected_unchanged(state) { T.submit(state, 0, :hit, now: 2) }
  T.assert(T.submit(state, 1, :stand))
  T.assert_equal({0 => 21, 1 => 19}, state[:scores])
  T.assert_equal(0, state[:outcome][:winner])
  T.assert_equal(source, Marshal.dump(decks))
  T.assert_equal(21, state[:outcome][:ceiling])
  automatic = T.start("blackjack", blackjack_decks: {0 => [1, 13], 1 => [1, 10]})
  T.assert(automatic[:finished])
  T.assert_equal([0, 1], automatic[:outcome][:tied])
end

{
  [1, 1, 5, 7] => [12, 17, 24],
  [3, 5, 1, 5] => [8, 19, 24],
  [5, 6, 1, 9] => [11, 12, 21],
  [4, 6, 1] => [10, 21],
  [9, 10, 1, 1] => [19, 20, 21],
  [1, 1, 1, 1, 8] => [12, 13, 14, 22]
}.each do |cards, totals|
  T.test("blackjack fixes each ace on draw: #{cards.join(', ')}") do
    state = T.start("blackjack", blackjack_decks: {0 => cards, 1 => [10, 9]})
    T.assert_equal(totals.first, E.public_view(state, viewer: 0)[:own][:total])
    totals.drop(1).each_with_index do |expected, index|
      restored = Marshal.load(Marshal.dump(state))
      [state, restored].each do |model|
        previous = model[:players][0][:total]
        T.assert(T.submit(model, 0, :hit, now: index + 1))
        T.assert_equal(expected, E.public_view(model, viewer: 0)[:own][:total])
        T.assert(expected > previous, 'Drawing a card reduced the fixed total')
        T.assert_equal([:challenge_draw, 0, cards[index + 2], expected], model[:notices].first)
      end
      T.assert_equal(Marshal.dump(state), Marshal.dump(restored), 'Checkpoint changed an assigned ace')
      T.rejected_unchanged(state) { T.submit(state, 0, :hit, now: index + 1, id: index + 1) }
    end
    T.assert_equal(totals.last > 21 ? :busted : :maximum, state[:players][0][:status])
    T.assert_equal(1, E.public_view(state, viewer: nil)[:turn_seat])
    T.assert(T.submit(state, 1, :stand, now: 100))
    T.assert_equal({0 => totals.last, 1 => 19}, state[:scores])
    T.assert_equal(totals.last > 21 ? 1 : 0, state[:outcome][:winner])
  end
end

T.test("blackjack keeps the whole attempt after drawing a queen to 18") do
  state = T.start("blackjack", blackjack_decks: {0 => [3, 5, 12, 2], 1 => [10, 9]})
  T.assert(T.submit(state, 0, :hit, now: 100))
  T.assert_equal(18, state[:players][0][:total])
  T.assert_equal(0, E.public_view(state, viewer: nil)[:turn_seat])
  T.rejected_unchanged(state) { T.submit(state, 1, :stand, now: 1_000) }
  T.rejected_unchanged(state) { E.expire(state, now_ms: 30_000) }
  T.assert(T.submit(state, 0, :hit, now: 30_099))
  T.assert_equal(20, state[:players][0][:total])
  T.assert_equal(0, E.public_view(state, viewer: nil)[:turn_seat])
  T.assert(T.submit(state, 0, :stand, now: 31_000))
  T.assert_equal(1, E.public_view(state, viewer: nil)[:turn_seat])
  T.assert(T.submit(state, 1, :stand, now: 31_001))
  T.assert_equal({0 => 20, 1 => 19}, state[:scores])
end

T.test("blackjack complete attempts advance only after stand maximum bust or timeout") do
  [2, 3, 8].product([:stood, :maximum, :busted, :timeout]).each do |count, ending|
    seats = [7, 2, 9, 4, 12, 0, 6, 15].first(count)
    last_rank = {stood: 2, maximum: 3, busted: 4, timeout: 2}.fetch(ending)
    decks = seats.to_h { |seat| [seat, [3, 5, 12, last_rank]] }
    state = T.start("blackjack", seats: seats, blackjack_decks: decks, now_ms: 100)
    order = T.turn_order(state)
    order.each_with_index do |seat, index|
      at = state[:turn_started_at_ms] + 100
      waiting = order[(index + 1) % count]
      T.assert_equal(seat, E.public_view(state, viewer: nil)[:turn_seat])
      T.rejected_unchanged(state) { T.submit(state, waiting, :hit, now: at) }
      T.assert(T.submit(state, seat, :hit, now: at))
      T.assert_equal(seat, E.public_view(state, viewer: nil)[:turn_seat])
      T.assert_equal(18, state[:players][seat][:total])
      T.assert_equal(at + 30_000, state[:deadline_ms])
      T.rejected_unchanged(state) { T.submit(state, seat, :hit, now: at + 1, id: 1) }
      T.rejected_unchanged(state) { T.submit(state, seat, :hit, now: at + 1, repeat: true) }
      T.rejected_unchanged(state) { T.submit(state, waiting, :stand, now: at + 1) }
      if ending == :timeout
        T.rejected_unchanged(state) { E.expire(state, now_ms: state[:deadline_ms] - 1) }
        T.assert(E.expire(state, now_ms: state[:deadline_ms]))
      else
        T.assert(T.submit(state, seat, ending == :stood ? :stand : :hit, now: at + 2))
      end
      T.assert_equal(ending, state[:players][seat][:status])
      T.assert_equal(index + 1, state[:players].count { |_key, player| player[:done] })
      T.assert_equal(order[index + 1], E.public_view(state, viewer: nil)[:turn_seat])
      T.rejected_unchanged(state) { T.submit(state, seat, :hit, now: state[:turn_started_at_ms] + 1) }
    end
    T.assert(state[:finished])
    T.assert_equal(seats, state[:results].keys)
  end
end

T.test("blackjack 20/24, all bust, tied valid leaders and timeout stand retain raw scores") do
  state = T.start("blackjack", blackjack_decks: {0 => [10, 10], 1 => [10, 9, 5]})
  T.assert(E.expire(state, now_ms: 30_000))
  T.assert(T.submit(state, 1, :hit, now: 30_001))
  T.assert_equal({0 => 20, 1 => 24}, state[:scores])
  T.assert_equal(0, state[:outcome][:winner])
  T.assert_equal(:busted, state[:results][1][:status])
  T.assert_equal(:timeout, state[:results][0][:status])
  all_bust = T.start("blackjack", blackjack_decks: {0 => [10, 10, 2], 1 => [10, 10, 8]})
  T.assert(T.submit(all_bust, 0, :hit))
  T.assert(T.submit(all_bust, 1, :hit))
  T.assert_equal({0 => 22, 1 => 28}, all_bust[:scores])
  T.assert_equal(nil, all_bust[:outcome][:winner])
  tied = T.start("blackjack", seats: [0, 1, 2], blackjack_decks: {0 => [10, 10], 1 => [10, 10], 2 => [10, 10, 8]})
  T.turn_order(tied).each { |seat| T.assert(T.submit(tied, seat, seat == 2 ? :hit : :stand)) }
  T.assert(tied[:finished])
  T.assert_equal([0, 1], tied[:outcome][:tied])
end

T.test("blackjack exhaustion is explicit and unseen decks are never exposed") do
  state = T.start("blackjack", blackjack_decks: {0 => [2, 3], 1 => [4, 5, 6]})
  state[:players][0][:deck].clear # Corrupt external setup cannot draw a phantom card.
  T.rejected_unchanged(state) { T.submit(state, 0, :hit) }
  mine = E.public_view(state, viewer: 0)
  T.assert_equal([2, 3], mine[:own][:card_ranks])
  T.assert(!mine[:own].key?(:deck) && !mine[:own].key?(:random))
  T.assert(!E.public_view(state, viewer: 1).key?(:results))
  T.assert(T.submit(state, 0, :stand))
  T.assert(T.submit(state, 1, :stand))
  T.assert(!E.public_view(state, viewer: nil)[:results][1].key?(:deck))
end

T.test("risky dice requires a roll, distinct presses, saves and never consumes effects") do
  source = {0 => {die_sides: 10, die_rolls: 1}, 1 => {die_sides: 3, die_rolls: 2}}
  before = Marshal.dump(source)
  state = T.start("risky_dice", dice: source)
  T.dice_sequence(state, 0, 8, 4, 10, 2)
  T.dice_sequence(state, 1, 3, 3)
  T.rejected_unchanged(state) { T.submit(state, 0, :save) }
  T.assert(T.submit(state, 0, :roll, now: 10))
  T.assert(T.submit(state, 0, :roll, now: 11))
  T.assert(T.submit(state, 0, :save, now: 12))
  T.assert(E.expire(state, now_ms: 30_012))
  T.assert_equal({0 => 24, 1 => 6}, state[:scores])
  T.assert_equal([[3, 3]], state[:results][1][:rolls])
  T.assert_equal(before, Marshal.dump(source))
  T.assert_equal(source, state[:dice])
end

T.test("risky dice maximum stops automatically; 24/28 and all-bust preserve penalties") do
  state = T.start("risky_dice", dice: {0 => {die_sides: 12, die_rolls: 3}, 1 => {die_sides: 12, die_rolls: 3}})
  T.dice_sequence(state, 0, 12, 12)
  T.dice_sequence(state, 1, 10, 10, 4, 4)
  T.assert(T.submit(state, 0, :roll))
  T.assert(T.submit(state, 0, :save, now: 2))
  T.assert(T.submit(state, 1, :roll, now: 2))
  T.assert(T.submit(state, 1, :roll, now: 2))
  T.assert_equal({0 => 24, 1 => 28}, state[:scores])
  T.assert_equal(0, state[:outcome][:winner])
  T.assert_equal(25, state[:outcome][:ceiling])
  exact = T.start("risky_dice", dice: {0 => {die_sides: 12, die_rolls: 1}})
  T.dice_sequence(exact, 0, 10, 10, 3, 2)
  T.assert(T.submit(exact, 0, :roll))
  T.assert(T.submit(exact, 0, :roll, now: 2))
  T.assert_equal(:maximum, exact[:players][0][:status])
  T.rejected_unchanged(exact) { T.submit(exact, 0, :roll, now: 3) }
  T.assert_equal(1, E.public_view(exact, viewer: nil)[:turn_seat])
  T.assert(T.submit(exact, 1, :roll, now: 3))
  T.assert(T.submit(exact, 1, :save, now: 4))
  T.assert_equal(0, exact[:outcome][:winner])

  all_bust = T.start("risky_dice", dice: [0, 1].to_h { |seat| [seat, {die_sides: 12, die_rolls: 1}] })
  [0, 1].each do |seat|
    T.dice_sequence(all_bust, seat, 12, 12, 2, 2)
    2.times { T.assert(T.submit(all_bust, seat, :roll)) }
  end
  T.assert_equal({0 => 28, 1 => 28}, all_bust[:scores])
  T.assert_equal(nil, all_bust[:outcome][:winner])
  T.assert(all_bust[:results].values.all? { |result| result[:status] == :busted })
end

[2, 3, 8].product([:save, :maximum, :busted, :timeout, :unstarted_timeout]).each do |count, completion|
  T.test("risky dice complete attempts in seat order: #{count} players, #{completion}") do
    seats = [7, 2, 9, 1, 14, 5, 3, 18].first(count)
    modifiers = seats.to_h { |seat| [seat, {die_sides: 12, die_rolls: 2}] }
    state = T.start("risky_dice", seats: seats, now_ms: 100, dice: modifiers)
    faces = {save: [2, 3, 4, 5], maximum: [10, 10, 3, 2], busted: [11, 11, 2, 3],
      timeout: [2, 3, 4, 5], unstarted_timeout: [2, 3]}.fetch(completion)
    seats.each { |seat| T.dice_sequence(state, seat, *faces) }
    now = 100
    order = T.turn_order(state)
    order.each_with_index do |seat, index|
      T.assert_equal(seat, E.public_view(state, viewer: nil)[:turn_seat])
      T.assert_equal(index, state[:players].count { |_other, player| player[:done] })
      other = order[(index + 1) % count]
      T.rejected_unchanged(state) { T.submit(state, other, :roll, now: now) }
      T.rejected_unchanged(state) { T.submit(state, seat, :save, now: now) }
      unless completion == :unstarted_timeout
        now += 10
        T.assert(T.submit(state, seat, :roll, now: now))
        T.assert_equal(seat, E.public_view(state, viewer: nil)[:turn_seat], "The next player started mid-attempt")
        T.assert_equal(now, state[:turn_started_at_ms])
        T.assert_equal(now + 30_000, state[:deadline_ms])
        first_deadline = state[:deadline_ms]
        T.rejected_unchanged(state) { T.submit(state, other, :roll, now: now + 1) }
        T.rejected_unchanged(state) { T.submit(state, seat, :roll, now: now + 1, id: 1) }
        T.rejected_unchanged(state) { T.submit(state, seat, :roll, now: now + 1, id: 2, repeat: true) }
        now = first_deadline - 1
        T.assert(T.submit(state, seat, :roll, now: now))
        T.assert_equal([faces.first(2), faces.last(2)], state[:players][seat][:rolls])
        unless state[:players][seat][:done]
          T.assert_equal(seat, E.public_view(state, viewer: nil)[:turn_seat])
          T.assert_equal(now, state[:turn_started_at_ms])
          T.assert_equal(now + 30_000, state[:deadline_ms])
          T.rejected_unchanged(state) { E.expire(state, now_ms: first_deadline) }
          T.rejected_unchanged(state) { T.submit(state, other, :roll, now: now + 1) }
        end
      end
      if completion == :save
        now += 2
        T.assert(T.submit(state, seat, :save, now: now))
      elsif [:timeout, :unstarted_timeout].include?(completion)
        now = state[:deadline_ms]
        previous_rolls = state[:players][seat][:rolls].dup
        T.rejected_unchanged(state) { T.submit(state, seat, :roll, now: now) }
        T.rejected_unchanged(state) { E.expire(state, now_ms: now - 1) }
        T.assert(E.expire(state, now_ms: now))
        if completion == :timeout
          T.assert_equal(previous_rolls, state[:players][seat][:rolls], "Timeout rerolled an existing attempt")
          T.assert_equal([[:challenge_stand, seat, 14]], state[:notices])
        else
          T.assert_equal([[2, 3]], state[:players][seat][:rolls])
          T.assert_equal([[:challenge_roll, seat, [2, 3], 5], [:challenge_stand, seat, 5]], state[:notices])
        end
      end
      status = {save: :saved, maximum: :maximum, busted: :busted,
        timeout: :timeout, unstarted_timeout: :timeout}.fetch(completion)
      T.assert(state[:players][seat][:done])
      T.assert_equal(status, state[:players][seat][:status])
      T.assert_equal(index + 1, state[:players].count { |_other, player| player[:done] })
      T.rejected_unchanged(state) { T.submit(state, seat, :roll, now: now + 1) }
      T.rejected_unchanged(state) { E.expire(state, now_ms: now) }
      T.assert_equal(order[index + 1], E.public_view(state, viewer: nil)[:turn_seat])
    end
    T.assert(state[:finished])
    T.assert_equal(now, state[:finished_at_ms])
    T.assert_equal(modifiers, state[:dice], "Challenge rolls consumed race modifiers")
    expected_total = {save: 14, maximum: 25, busted: 27, timeout: 14, unstarted_timeout: 5}.fetch(completion)
    T.assert_equal(seats.to_h { |seat| [seat, expected_total] }, state[:scores])
  end
end

T.test("guess number bounds, strict parsing, tenth attempt and best-not-last ranking") do
  state = T.start("guess_number")
  secret = state[:answer]
  [0, 1_000, 1.5, "12x", " 12", "1e1", "", "1\n", true, "99999999999"].each do |input|
    T.rejected_unchanged(state) { T.submit(state, 0, :answer, input) }
  end
  closest = secret < 999 ? secret + 1 : secret - 1
  distant = secret > 500 ? 1 : 999
  T.assert(T.submit(state, 0, :answer, closest, now: 10))
  9.times { |index| T.assert(T.submit(state, 0, :answer, distant, now: 11 + index)) }
  T.assert_equal(10, state[:players][0][:attempts].length)
  T.assert_equal(closest, state[:players][0][:best][:value])
  T.rejected_unchanged(state) { T.submit(state, 0, :answer, secret, now: 30) }
  T.assert(T.submit(state, 1, :answer, distant, now: 30))
  T.finish_by_timeout(state)
  T.assert_equal(0, state[:outcome][:winner])
  T.assert(state[:outcome][:settlement_ready])
  T.assert_equal(:guess_number, state[:outcome][:kind])
  T.assert(!state[:outcome].key?(:amount), 'Guessing still has a flat stake')
  T.assert_equal([], state[:outcome][:unresolved])
end

T.test("exact guesses outrank approximations, but time and attempt count never break a distance tie") do
  state = T.start("guess_number", seats: [0, 1, 2])
  secret = state[:answer]
  wrong = secret == 1 ? 2 : secret - 1
  T.assert(T.submit(state, 0, :answer, wrong, now: 10))
  T.assert(T.submit(state, 0, :answer, secret, now: 20))
  T.assert(T.submit(state, 1, :answer, secret, now: 900))
  T.assert(T.submit(state, 2, :answer, wrong, now: 1))
  T.finish_by_timeout(state)
  T.assert_equal(nil, state[:outcome][:winner])
  T.assert_equal([0, 1], state[:outcome][:tied])
  tied = T.start("guess_number")
  T.assert(T.submit(tied, 0, :answer, tied[:answer], now: 151))
  T.assert(T.submit(tied, 1, :answer, tied[:answer], now: 249))
  T.assert_equal([0, 1], tied[:outcome][:tied])
  faster = T.start("guess_number")
  T.assert(T.submit(faster, 0, :answer, faster[:answer], now: 149))
  T.assert(T.submit(faster, 1, :answer, faster[:answer], now: 150))
  T.assert_equal(nil, faster[:outcome][:winner])
  T.assert_equal([0, 1], faster[:outcome][:tied])
end

T.test("closest-distance ties ignore speed, absent guesses cannot win and feedback stays private") do
  state = T.start("guess_number")
  secret = state[:answer]
  guess = secret == 999 ? 998 : secret + 1
  T.assert(T.submit(state, 0, :answer, guess, now: 1))
  T.assert(T.submit(state, 1, :answer, guess, now: 29_999))
  own = E.public_view(state, viewer: 0)[:own]
  T.assert_equal(:lower, own[:attempts].last[:feedback]) if guess > secret
  T.assert(!own.key?(:best))
  T.assert(own[:attempts].all? { |attempt| !attempt.key?(:distance) })
  T.assert(!E.public_view(state, viewer: 1).key?(:answer))
  T.assert(!E.public_view(state, viewer: nil).key?(:results))
  T.finish_by_timeout(state)
  T.assert_equal([0, 1], state[:outcome][:tied])
  empty = T.start("guess_number")
  T.finish_by_timeout(empty)
  T.assert_equal(nil, empty[:outcome][:winner])
  T.assert(empty[:outcome][:settlement_ready])
end

T.test("copy number uses three submissions, retains wrong attempts and early completion") do
  state = T.start("copy_number")
  T.assert(state[:question][:number].between?(100, 999))
  answer = state[:question][:number]
  T.assert(T.submit(state, 0, :answer, answer + 1))
  T.assert(T.submit(state, 0, :answer, answer + 2, now: 2))
  T.assert(T.submit(state, 0, :answer, answer.to_s, now: 3))
  T.assert_equal(3, state[:players][0][:attempts].size)
  T.rejected_unchanged(state) { T.submit(state, 0, :answer, answer, now: 4) }
  T.assert(T.submit(state, 1, :answer, answer, now: 5_000))
  T.assert(state[:finished])
  T.assert_equal({0 => 0, 1 => 50}, state[:scores])
  T.assert_equal(0, state[:outcome][:winner])
  T.assert(state[:outcome][:settlement_ready])
end

T.test("speed rounding boundaries, failed-participant full-time fallback and nobody correct") do
  [0, 49, 50, 149, 150, 999, 1_000, 1_049, 1_050].each do |time|
    state = T.start("copy_number")
    T.assert(T.submit(state, 0, :answer, state[:answer], now: time))
    T.assert_equal((time + 50) / 100, state[:players][0][:elapsed_tenths])
  end
  partial = T.start("copy_number")
  T.assert(T.submit(partial, 0, :answer, partial[:answer]))
  3.times { |index| T.assert(T.submit(partial, 1, :answer, -999, now: index + 1)) }
  T.assert(partial[:finished])
  T.assert_equal(0, partial[:outcome][:winner])
  T.assert(partial[:outcome][:settlement_ready])
  T.assert_equal([], partial[:outcome][:unresolved])
  T.assert_equal(150, partial[:outcome][:time_limit])
  T.assert_equal(nil, partial[:scores][1], "failed answer must not become a winning time")
  none = T.start("copy_number")
  T.finish_by_timeout(none)
  T.assert_equal(nil, none[:outcome][:winner])
  T.assert(none[:outcome][:settlement_ready])
end

T.test("arithmetic covers all operators, integer answers and promised operand limits") do
  covered = []
  250.times do |seed|
    state = T.start("arithmetic", seed: seed)
    question = state[:question]
    left, right = question.values_at(:left, :right)
    operation = question[:operation]
    covered << operation
    expected = case operation
    when :add
      T.assert(left.between?(0, 100) && right.between?(0, 100) && left + right <= 100)
      left + right
    when :subtract
      T.assert(left.between?(0, 100) && right.between?(0, left))
      left - right
    when :multiply
      T.assert(left.between?(2, 12) && right.between?(2, 12))
      left * right
    when :divide
      T.assert(right.between?(2, 12) && (left % right).zero?)
      left / right
    end
    T.assert_equal(expected, state[:answer])
    T.assert(!E.public_view(state, viewer: 0).key?(:answer))
    T.assert(T.submit(state, 0, :answer, expected.to_s))
    T.assert(T.submit(state, 1, :answer, expected, now: 200))
    T.assert(state[:finished])
  end
  T.assert_equal([:add, :divide, :multiply, :subtract], covered.uniq.sort)
end

T.test("race questions use immutable public facts, omit tied rankings and allow two attempts") do
  snapshot = {
    racers: {0 => {progress: 35, feathers: 18, card_count: 3}, 1 => {progress: 35, feathers: 10, card_count: 2}},
    board_length: 30, laps: 3
  }
  seen = []
  60.times do |seed|
    state = T.start("race_question", seed: seed, race_snapshot: snapshot)
    question = state[:question]
    racer = snapshot[:racers].fetch(question[:seat])
    expected = {square: 6, lap: 2, feathers: racer[:feathers], card_count: racer[:card_count]}.fetch(question[:field])
    T.assert_equal(expected, state[:answer])
    seen << question[:field]
  end
  T.assert_equal([:card_count, :feathers, :lap, :square], seen.uniq.sort)
  state = T.start("race_question", race_snapshot: snapshot)
  answer = state[:answer]
  snapshot[:racers][0][:progress] = 999
  snapshot[:racers][1][:feathers] = 888
  T.assert_equal(answer, state[:answer])
  T.assert(T.submit(state, 0, :answer, -1))
  T.assert(T.submit(state, 0, :answer, answer, now: 2))
  T.assert(T.submit(state, 1, :answer, -1))
  T.assert(T.submit(state, 1, :answer, -1, now: 2))
  T.assert(state[:finished])
  T.rejected_unchanged(state) { T.submit(state, 1, :answer, answer, now: 3) }
  T.assert_raises(ArgumentError) { T.start("race_question") }
  T.assert_raises(ArgumentError) { T.start("race_question", race_snapshot: {racers: {}, board_length: 30}) }
end

T.test("numbered balls are ordered, include negatives, take immediately and reject oversized counts") do
  state = T.start("numbered_balls")
  T.assert_equal(12, state[:remaining].size)
  T.assert(state[:remaining].all? { |ball| E::BALL_VALUES.include?(ball) })
  state[:remaining] = [10, -7, 3, -10, -3, 2, 7, -2, 1, -1, 10, -7]
  first = state[:participants][state[:turn_index]]
  other = 1 - first
  T.rejected_unchanged(state) { T.submit(state, other, :take, 1) }
  T.assert(T.submit(state, first, :take, "3", now: 100))
  T.assert_equal([10, -7, 3], state[:players][first][:balls])
  T.assert_equal(6, state[:players][first][:total])
  T.assert_equal(-10, E.public_view(state, viewer: nil)[:remaining].first)
  T.rejected_unchanged(state) { T.submit(state, other, :take, 1, now: 99) }
  3.times do |index|
    seat = state[:participants][state[:turn_index]]
    T.assert(T.submit(state, seat, :take, 3, now: 101 + index))
  end
  T.assert(state[:finished])
  T.assert_equal(3, state[:scores].values.sum)
  small = T.start("numbered_balls")
  small[:remaining] = [2, -1]
  seat = small[:participants][small[:turn_index]]
  T.rejected_unchanged(small) { T.submit(small, seat, :take, 3) }
  T.assert(T.submit(small, seat, :take, 2))
  T.assert(small[:finished])
end

T.test("ball turn deadlines are exact, sparse expiry is deterministic and never consumes twice") do
  state = T.start("numbered_balls")
  first = state[:participants][state[:turn_index]]
  T.rejected_unchanged(state) { T.submit(state, first, :take, 1, now: 60_000) }
  T.assert_equal(false, E.expire(state, now_ms: 59_999))
  sparse = Marshal.load(Marshal.dump(state))
  notices = []
  12.times do |turn|
    T.assert(E.expire(state, now_ms: (turn + 1) * 60_000))
    notices.concat(state[:notices])
  end
  T.assert(E.expire(sparse, now_ms: 999_999))
  T.assert_equal(notices, sparse[:notices], 'Sparse expiry lost or duplicated public ball picks')
  T.assert_equal(Marshal.dump(state.reject { |key, _| key == :notices }),
    Marshal.dump(sparse.reject { |key, _| key == :notices }))
  T.assert_equal(720_000, state[:finished_at_ms])
  T.assert_equal(6, state[:results][first][:balls].length)
  T.assert_equal(6, state[:results][1 - first][:balls].length)
  T.rejected_unchanged(state) { E.expire(state, now_ms: 1_000_000) }
end

T.test("accepted log replay, marshal checkpoint and next RNG values match") do
  state = T.start("risky_dice", seats: [2, 7], seed: 345)
  replay = T.start("risky_dice", seats: [2, 7], seed: 345)
  first, second = T.turn_order(state)
  actions = [
    [first, {kind: :roll, press_id: 1}, 100], [first, {kind: :roll, press_id: 2}, 200],
    [first, {kind: :save, press_id: 3}, 300], [second, {kind: :roll, press_id: 1}, 500]
  ]
  actions.each do |seat, action, now|
    T.assert(E.submit(state, seat: seat, action: action, now_ms: now))
    T.assert(E.submit(replay, seat: seat, action: action, now_ms: now))
  end
  restored = Marshal.load(Marshal.dump(state))
  [state, replay, restored].each { |model| T.assert(E.expire(model, now_ms: 30_500)) }
  T.assert_equal(Marshal.dump(state), Marshal.dump(replay))
  T.assert_equal(Marshal.dump(state), Marshal.dump(restored))
  [2, 7].each do |seat|
    expected = state[:players][seat][:random].rand(10_000)
    T.assert_equal(expected, replay[:players][seat][:random].rand(10_000))
    T.assert_equal(expected, restored[:players][seat][:random].rand(10_000))
  end
end

T.test("full physical blackjack decks are distinct and never exhaust before the hand ends") do
  200.times do |seed|
    state = T.start("blackjack", seats: (0..7).to_a, seed: seed)
    state[:players].each_value do |player|
      T.assert_equal(E::BLACKJACK_CARDS, (player[:cards] + player[:deck]).sort)
      T.assert_equal((1..13).to_h { |rank| [rank, 4] }, (player[:cards] + player[:deck]).map { |id| id / 4 + 1 }.tally)
    end
    until state[:finished]
      seat = E.public_view(state, viewer: nil).fetch(:turn_seat)
      T.assert(!state[:players][seat][:deck].empty?)
      T.assert(T.submit(state, seat, :hit))
    end
    state[:participants].each do |seat|
      T.assert(state[:players][seat][:cards].length <= 13)
      T.assert_equal(state[:players][seat][:cards].uniq.length, state[:players][seat][:cards].length)
    end
    T.assert(state[:finished])
  end
  # With aces first, the first ace stays at 11. Four aces and four twos
  # therefore bust at 22; they cannot be revalued to prolong the attempt.
  low_first = E.start("blackjack", seats: [0, 1], seed: 1, now_ms: 0,
    blackjack_decks: {0 => E::BLACKJACK_CARDS, 1 => E::BLACKJACK_CARDS})
  until low_first[:finished]
    seat = E.public_view(low_first, viewer: nil).fetch(:turn_seat)
    T.assert(T.submit(low_first, seat, :hit))
  end
  T.assert_equal({0 => 22, 1 => 22}, low_first[:scores])
  T.assert_equal(8, low_first[:players][0][:cards].length)
  [false, {0 => [0] * 52, 1 => E::BLACKJACK_CARDS}, {0 => E::BLACKJACK_CARDS}].each do |decks|
    T.assert_raises(ArgumentError) { E.start("blackjack", seats: [0, 1], seed: 1, now_ms: 0, blackjack_decks: decks) }
  end
end

T.test("blackjack choices from different seats do not alter each other's future draw") do
  first = T.start("blackjack", seed: 77)
  second = T.start("blackjack", seats: [1, 0], seed: 77)
  T.turn_order(first).each do |seat|
    T.assert(T.submit(first, seat, :hit, now: 1)) unless first[:players][seat][:done]
    T.assert(T.submit(first, seat, :stand, now: 1)) unless first[:players][seat][:done]
  end
  T.turn_order(second).each do |seat|
    T.assert(T.submit(second, seat, :hit, now: 1)) unless second[:players][seat][:done]
    T.assert(T.submit(second, seat, :stand, now: 1)) unless second[:players][seat][:done]
  end
  T.assert_equal(Marshal.dump(first[:players].sort.to_h), Marshal.dump(second[:players].sort.to_h))
end

T.test("every numeric challenge survives a checkpoint without changing subsequent decisions") do
  snapshot = {racers: {0 => {progress: 2, feathers: 3, card_count: 4},
    1 => {progress: 32, feathers: 5, card_count: 6}}, board_length: 30, laps: 3}
  E::TYPES.each_key do |type|
    live = T.start(type, seed: 789, race_snapshot: snapshot)
    checkpoint = Marshal.load(Marshal.dump(live))
    cases = case type
    when "rock_paper_scissors" then [[0, :choose, "rock"], [1, :choose, "paper"]]
    when "dice_duel" then T.turn_order(live).map { |seat| [seat, :roll, T::UNSET] }
    when "risky_dice" then T.turn_order(live).flat_map { |seat| [[seat, :roll, T::UNSET], [seat, :save, T::UNSET]] }
    when "blackjack" then T.turn_order(live).map { |seat| [seat, :stand, T::UNSET] }
    when "guess_number", *E::ANSWER_TYPES then [[0, :answer, live[:answer]], [1, :answer, live[:answer]]]
    when "numbered_balls" then [[live[:participants][live[:turn_index]], :take, 3]]
    end
    cases.each do |seat, kind, value|
      expected = T.submit(live, seat, kind, value, now: 5)
      actual = T.submit(checkpoint, seat, kind, value, now: 5)
      T.assert_equal(expected, actual)
    end
    [live, checkpoint].each { |model| E.expire(model, now_ms: 1_000_000) }
    T.assert_equal(Marshal.dump(live), Marshal.dump(checkpoint), type)
    T.assert(live[:finished], type)
  end
end

T.test("dice duel rotates after every roll and blackjack skips initially completed seats") do
  %w[dice_duel].each do |type|
    setup = {seats: [7, 2, 9], now_ms: 100}
    state = T.start(type, **setup)
    first, second, third = T.turn_order(state)
    T.assert_equal([], state[:notices])
    T.assert_equal(first, E.public_view(state, viewer: nil)[:turn_seat])
    T.assert_equal(100, E.public_view(state, viewer: nil)[:turn_started_at_ms])
    action = :roll
    T.rejected_unchanged(state) { T.submit(state, second, action, now: 101) }
    T.assert(T.submit(state, first, action, now: 111))
    T.assert_equal(second, E.public_view(state, viewer: first)[:turn_seat])
    T.assert_equal(111, state[:turn_started_at_ms])
    T.assert_equal(111 + E::TYPES.fetch(type)[2], state[:deadline_ms])
    T.rejected_unchanged(state) { T.submit(state, second, action, now: 110) }
    T.rejected_unchanged(state) { T.submit(state, first, action, now: 112) }
    T.assert(T.submit(state, second, action, now: 112))
    T.assert_equal(third, E.public_view(state, viewer: second)[:turn_seat])
    T.assert(T.submit(state, third, action, now: 113))
    T.assert(state[:finished])
    T.assert_equal(nil, E.public_view(state, viewer: nil)[:turn_seat])
    T.assert_equal(113, state[:finished_at_ms])
  end

  state = T.start("blackjack", seats: [7, 2, 9], now_ms: 50,
    blackjack_decks: {7 => [1, 13], 2 => [2, 3, 4, 5], 9 => [1, 12]})
  T.assert_equal(2, E.public_view(state, viewer: nil)[:turn_seat], "Initial 21 must skip that seat")
  T.assert_equal([[:challenge_hand, 2, [2, 3], 5]], state[:notices])
  T.assert(T.submit(state, 2, :hit, now: 75))
  T.assert_equal(2, E.public_view(state, viewer: nil)[:turn_seat], "The last unfinished player keeps deciding")
  T.assert_equal(30_075, state[:deadline_ms])
  T.assert(T.submit(state, 2, :stand, now: 76))
  T.assert_equal([[:challenge_stand, 2, 9], [:challenge_hand, 9, [1, 12], 21],
    [:challenge_hand, 7, [1, 13], 21]], state[:notices])
  T.assert_equal(nil, E.public_view(state, viewer: nil)[:turn_seat])
  T.assert_equal({7 => 21, 2 => 9, 9 => 21}, state[:scores])
end

T.test("turn timeouts affect only the current seat and catch up from recorded deadlines") do
  %w[dice_duel blackjack risky_dice].each do |type|
    setup = {seats: [5, 1, 8, 2], now_ms: 37}
    setup[:blackjack_decks] = setup[:seats].to_h { |seat| [seat, [2, 3, 4]] } if type == "blackjack"
    state = T.start(type, **setup)
    sparse = Marshal.load(Marshal.dump(state))
    limit = E::TYPES.fetch(type)[2]
    expected_notices = []
    order = T.turn_order(state)
    order.each_with_index do |seat, index|
      at = 37 + (index + 1) * limit
      action = type == "blackjack" ? :stand : :roll
      T.rejected_unchanged(state) { T.submit(state, seat, action, now: at) }
      T.rejected_unchanged(state) { E.expire(state, now_ms: at - 1) }
      T.assert(E.expire(state, now_ms: at))
      expected_notices.concat(state[:notices])
      T.assert_equal(index + 1, state[:players].count { |_other, player| player[:done] })
      T.assert_equal(index == 3, state[:finished])
      next if state[:finished]
      T.assert_equal(order[index + 1], E.public_view(state, viewer: nil)[:turn_seat])
      T.assert_equal(at, state[:turn_started_at_ms])
      T.assert_equal(at + limit, state[:deadline_ms])
    end
    T.assert(E.expire(sparse, now_ms: 999_999))
    T.assert_equal(expected_notices, sparse[:notices], "A delayed poll lost or duplicated an automatic action")
    T.assert_equal(Marshal.dump(state.reject { |key, _value| key == :notices }),
      Marshal.dump(sparse.reject { |key, _value| key == :notices }), "Polling frequency changed model or RNG")
    T.assert_equal(37 + 4 * limit, state[:finished_at_ms])
    T.rejected_unchanged(sparse) { E.expire(sparse, now_ms: 1_000_000) }
  end
end

T.test("accepted actions publish only fresh roll draw and stand notices with detached public copies") do
  dice = T.start("dice_duel")
  T.dice_sequence(dice, 0, 5)
  T.dice_sequence(dice, 1, 3)
  T.assert(T.submit(dice, 0, :roll, now: 10))
  T.assert_equal([[:challenge_roll, 0, [5], 5]], dice[:notices])
  T.rejected_unchanged(dice) { T.submit(dice, 0, :roll, now: 11) }
  view = E.public_view(dice, viewer: nil)
  T.assert_equal(dice[:notices], view[:notices])
  view[:notices][0][2] << 99
  T.assert_equal([[:challenge_roll, 0, [5], 5]], dice[:notices])
  T.assert(E.expire(dice, now_ms: 10_010))
  T.assert_equal([[:challenge_roll, 1, [3], 3]], dice[:notices])

  cards = T.start("blackjack", blackjack_decks: {0 => [2, 3, 13], 1 => [4, 5]})
  T.assert_equal([[:challenge_hand, 0, [2, 3], 5]], cards[:notices])
  T.assert(T.submit(cards, 0, :hit, now: 10))
  T.assert_equal([[:challenge_draw, 0, 13, 15]], cards[:notices])
  T.rejected_unchanged(cards) { T.submit(cards, 1, :stand, now: 11) }
  T.assert(E.expire(cards, now_ms: 30_010))
  T.assert_equal([[:challenge_stand, 0, 15], [:challenge_hand, 1, [4, 5], 9]], cards[:notices])
  T.assert(T.submit(cards, 1, :stand, now: 30_011))
  T.assert_equal([[:challenge_stand, 1, 9]], cards[:notices])

  risky = T.start("risky_dice")
  T.dice_sequence(risky, 0, 2, 3, 4, 5)
  T.dice_sequence(risky, 1, 1, 6)
  T.assert(T.submit(risky, 0, :roll, now: 10))
  T.assert_equal([[:challenge_roll, 0, [2, 3], 5]], risky[:notices])
  view = E.public_view(risky, viewer: nil)
  view[:notices][0][2] << 99
  T.assert_equal([[:challenge_roll, 0, [2, 3], 5]], risky[:notices])
  T.assert(T.submit(risky, 0, :roll, now: 20))
  T.assert_equal([[:challenge_roll, 0, [4, 5], 14]], risky[:notices])
  T.assert(T.submit(risky, 0, :save, now: 30))
  T.assert_equal([[:challenge_stand, 0, 14]], risky[:notices])
  T.assert(E.expire(risky, now_ms: 30_030))
  T.assert_equal([[:challenge_roll, 1, [1, 6], 7], [:challenge_stand, 1, 7]], risky[:notices])

  timeout = T.start("risky_dice")
  T.assert(T.submit(timeout, 0, :roll, now: 10))
  T.assert(T.submit(timeout, 0, :roll, now: 20))
  previous_rolls = timeout[:players][0][:rolls].dup
  T.assert(E.expire(timeout, now_ms: 30_020))
  T.assert_equal(previous_rolls, timeout[:players][0][:rolls], "Saving at timeout must not roll again")
  T.assert_equal([[:challenge_stand, 0, timeout[:players][0][:total]]], timeout[:notices])
end

report_dir = File.expand_path("../../../tmp/duck-racing", __dir__)
FileUtils.mkdir_p(report_dir)
report_path = File.join(report_dir, "numeric-local.json")
previous = File.file?(report_path) ? JSON.parse(File.read(report_path)).fetch("runs", []) : []
run = {scope: "Pure numeric challenge engines; no UI, networking or live games",
  filter: T.case_filter&.source,
  results: T.results, passed: T.results.count { |result| result[:status] == "PASS" },
  failed: T.results.count { |result| result[:status] == "FAIL" }}
File.write(report_path, JSON.pretty_generate({runs: previous + [run]}) + "\n")
puts "#{run[:passed]}/#{T.results.size} numeric challenge scenarios passed"
raise "No numeric cases matched #{T.case_filter.inspect}" if T.results.empty?
exit(run[:failed].zero? ? 0 : 1)
