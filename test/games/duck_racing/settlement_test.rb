require_relative "../../support/assertions"
require_relative "../../../games/duck_racing_support/settlement"

include GameRoomTest::Assertions
missing_speed = GameRoomDuckRacing::Settlement.speed(balances: {a: 20, b: 20}, times: {a: 51, b: nil}, time_limit: 200)
assert_equal(:a, missing_speed.winner)
assert_equal({a: 25, b: 15}, missing_speed.balances)
no_speed = GameRoomDuckRacing::Settlement.speed(balances: {a: 20, b: 20}, times: {a: nil, b: nil}, time_limit: 200)
assert_equal(nil, no_speed.winner)
assert_equal({a: 20, b: 20}, no_speed.balances)
assert_equal(:no_winner, no_speed.outcome)
rounded_speed = GameRoomDuckRacing::Settlement.speed(balances: {a: 20, b: 20}, times: {a: 200, b: nil}, time_limit: 200)
assert_equal(:a, rounded_speed.winner, "a missing answer tied a rounded successful answer")
assert_equal([5], rounded_speed.transfers.map(&:amount))
assert_raises(ArgumentError) do
  GameRoomDuckRacing::Settlement.speed(balances: {a: 20}, times: {a: nil})
end
assert_raises(ArgumentError) do
  GameRoomDuckRacing::Settlement.speed(balances: {a: 20}, times: {a: 201}, time_limit: 200)
end
settlement = GameRoomDuckRacing::Settlement
balances = {"A" => 20, "B" => 20, "C" => 20}.freeze
result = settlement.difference(balances: balances, scores: {"A" => 16, "B" => 10, "C" => 8})
assert_equal("A", result.winner)
assert_equal({"A" => 34, "B" => 14, "C" => 12}, result.balances)
assert_equal([6, 8], result.transfers.map(&:amount))
assert_equal(60, result.balances.values.sum)
assert_equal({"A" => 20, "B" => 20, "C" => 20}, balances, "settlement changed its input")
assert(result.frozen? && result.balances.frozen? && result.transfers.frozen?, "settlement result is mutable")

tie = settlement.difference(balances: balances, scores: {"A" => 16, "B" => 16, "C" => 0})
assert_equal(nil, tie.winner)
assert_equal(balances, tie.balances)
assert_equal([], tie.transfers)
assert_equal(:draw, tie.outcome)
assert_equal(:won, result.outcome)
limited = settlement.difference(balances: {"A" => 0, "B" => 2, "C" => 1}, scores: {"A" => 16, "B" => 10, "C" => 8})
assert_equal({"A" => 3, "B" => 0, "C" => 0}, limited.balances)

[[21, 20, 24], [25, 24, 28]].each do |ceiling, winner_score, busted_score|
  outcome = settlement.difference(balances: {"A" => 10, "B" => 10},
    scores: {"A" => winner_score, "B" => busted_score}, ceiling: ceiling)
  assert_equal({"A" => 14, "B" => 3}, outcome.balances)
  assert_equal({"B" => 3}, outcome.burned)
  poor = settlement.difference(balances: {"A" => 10, "B" => 5},
    scores: {"A" => winner_score, "B" => busted_score}, ceiling: ceiling)
  assert_equal({"A" => 14, "B" => 0}, poor.balances, "bust penalty was paid before the winner")
  assert_equal({"B" => 1}, poor.burned)
end
tie_bust = settlement.difference(balances: balances, scores: {"A" => 20, "B" => 20, "C" => 24}, ceiling: 21)
assert_equal(nil, tie_bust.winner)
assert_equal([], tie_bust.transfers)
assert_equal({"A" => 20, "B" => 20, "C" => 17}, tie_bust.balances)
assert_equal(:draw, tie_bust.outcome)
all_bust = settlement.difference(balances: {"A" => 3, "B" => 8}, scores: {"A" => 30, "B" => 24}, ceiling: 21)
assert_equal(nil, all_bust.winner)
assert_equal({"A" => 0, "B" => 5}, all_bust.balances)
assert_equal(:no_winner, all_bust.outcome)
negative = settlement.difference(balances: {"A" => 20, "B" => 20}, scores: {"A" => -4, "B" => -9})
assert_equal({"A" => 25, "B" => 15}, negative.balances, "signed ball scores were treated as invalid")

capped = settlement.difference(balances: balances, scores: {"A" => 30, "B" => 0, "C" => 25}, max_transfer: 10)
assert_equal([10, 5], capped.transfers.map(&:amount))
assert_equal({"A" => 35, "B" => 10, "C" => 15}, capped.balances)
assert_equal([], settlement.difference(balances: balances,
  scores: {"A" => 30, "B" => 0, "C" => 25}, max_transfer: 0).transfers)
[-1, 1.5, '10'].each do |invalid|
  assert_raises(ArgumentError) { settlement.difference(balances: {0 => 20, 1 => 20},
    scores: {0 => 30, 1 => 0}, max_transfer: invalid) }
end

{0 => 0, 1 => 1, 9 => 1, 10 => 1, 11 => 2, 20 => 2, 21 => 3, 50 => 5, 51 => 5, 140 => 5, 449 => 5}.each do |gap, expected|
  outcome = settlement.speed(balances: {"A" => 100, "B" => 100}, times: {"A" => 3, "B" => 3 + gap})
  assert_equal({"A" => 100 + expected, "B" => 100 - expected}, outcome.balances)
end
speed_tie = settlement.speed(balances: balances, times: {"A" => 15, "B" => 15, "C" => 99})
assert_equal(balances, speed_tie.balances)
assert_equal(:draw, speed_tie.outcome)
eight = settlement.speed(balances: (0...8).to_h { |seat| [seat, seat] },
  times: (0...8).to_h { |seat| [seat, seat.zero? ? 1 : (seat.odd? ? nil : 200)] }, time_limit: 200)
assert_equal(0, eight.winner)
assert(eight.transfers.all? { |transfer| transfer.amount <= 5 })
assert_equal(28, eight.balances.values.sum)
assert_equal({0 => 25, 1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0, 6 => 1, 7 => 2}, eight.balances)
[[90, 60, 3], [100, 40, 6], [83, 79, 1], [Rational(501, 10), 50, 1], [0, 0, 0]].each do |best, other, expected|
  outcome = settlement.accuracy(balances: {"A" => 20, "B" => 20}, percentages: {"A" => best, "B" => other})
  assert_equal({"A" => 20 + expected, "B" => 20 - expected}, outcome.balances)
end

assert_equal({"A" => 23, "B" => 17}, settlement.fixed(balances: {"A" => 20, "B" => 20}, winner: "A", amount: 3).balances)
assert_equal({"A" => 3, "B" => 0}, settlement.fixed(balances: {"A" => 0, "B" => 3}, winner: "A", amount: 5).balances)
quiz = settlement.quiz(balances: {"A" => 0, "B" => 2, "C" => 8}, answers: {"A" => true, "B" => false, "C" => true})
assert_equal({"A" => 4, "B" => 2, "C" => 12}, quiz.balances)
assert_equal({"A" => 4, "C" => 4}, quiz.grants)
assert_equal([], quiz.transfers)
assert_equal(:quiz, quiz.outcome)
assert_equal(:quiz, settlement.quiz(balances: {0 => 10, 1 => 10}, answers: {0 => false, 1 => false}).outcome)
assert_equal(:no_winner, settlement.difference(balances: {0 => 10, 1 => 10},
  scores: {0 => 0, 1 => 0}, eligible: []).outcome, 'Missing results became a draw')
assert_equal(:no_winner, settlement.fixed(balances: {0 => 10, 1 => 10}, winner: nil, amount: 3).outcome)
assert_equal(:draw, settlement.fixed(balances: {0 => 10, 1 => 10}, winner: nil, amount: 3, draw: true).outcome)
assert_raises(ArgumentError) { settlement.fixed(balances: {0 => 10, 1 => 10}, winner: 0, amount: 3, draw: true) }

assert_raises(ArgumentError) { settlement.difference(balances: {"A" => -1}, scores: {"A" => 1}) }
assert_raises(ArgumentError) { settlement.difference(balances: {"A" => 1}, scores: {"B" => 1}) }
assert_raises(ArgumentError) { settlement.speed(balances: {"A" => 1}, times: {"A" => nil}) }
assert_raises(ArgumentError) { settlement.speed(balances: {"A" => 1}, times: {"A" => -1}) }
assert_raises(ArgumentError) { settlement.accuracy(balances: {"A" => 1}, percentages: {"A" => Float::NAN}) }
assert_raises(ArgumentError) { settlement.accuracy(balances: {"A" => 1}, percentages: {"A" => 101}) }
assert_raises(ArgumentError) { settlement.fixed(balances: {"A" => 1}, winner: "B", amount: 3) }
assert_raises(ArgumentError) { settlement.quiz(balances: {"A" => 1}, answers: {"A" => "yes"}) }

# Seeded property checks: all transfers conserve feathers; only the recorded
# bust penalties remove them. Include many ties and insufficient balances.
random = Random.new(203)
1000.times do
  funds = (0...random.rand(2..8)).to_h { |seat| [seat, random.rand(0..30)] }
  scores = funds.to_h { |seat, _| [seat, random.rand(0..40)] }
  outcome = settlement.difference(balances: funds, scores: scores, ceiling: 25)
  assert(outcome.balances.values.all? { |value| value >= 0 }, "settlement created a debt")
  assert_equal(funds.values.sum, outcome.balances.values.sum + outcome.burned.values.sum)
  assert_equal(outcome, settlement.difference(balances: funds, scores: scores, ceiling: 25))
end
puts "PASS Duck Racing difference, ties, busts, speed, accuracy, fixed stakes, quiz and conservation"
