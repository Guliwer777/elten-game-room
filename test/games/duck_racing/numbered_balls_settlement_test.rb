require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

[[4, 4, 0], [10, 3, 7], [10, 0, 10], [30, -20, 10], [-2, -20, 10]].each do |high, low, amount|
  [0, 1].each do |winner|
    scores = {winner => {score: high}, 1 - winner => {score: low}}
    outcome = ENGINE.settlement('numbered_balls', balances: {0 => 30, 1 => 30}, results: scores)
    assert_equal(amount.zero? ? nil : winner, outcome.winner)
    assert_equal(amount.zero? ? [] : [amount], outcome.transfers.map(&:amount))
    assert_equal(60, outcome.balances.values.sum)
    assert_equal({}, outcome.burned)
  end
end

[0, 3, 10].each do |funds|
  outcome = ENGINE.settlement('numbered_balls', balances: {0 => 20, 1 => funds},
    results: {0 => {score: 30}, 1 => {score: -20}})
  assert_equal({0 => 20 + funds, 1 => 0}, outcome.balances)
end
excluded = ENGINE.settlement('numbered_balls', balances: {0 => 20, 1 => 20},
  results: {0 => {score: 30}, 1 => {score: -20}}, excluded: [0, 1])
assert_equal(nil, excluded.winner)
assert_equal([], excluded.transfers)

# The cap belongs to balls, not all difference-based challenges.
%w[simon dice_duel sound_memory].each do |kind|
  outcome = ENGINE.settlement(kind, balances: {0 => 30, 1 => 30},
    results: {0 => {score: 25}, 1 => {score: 3}})
  assert_equal([22], outcome.transfers.map(&:amount), "The balls cap leaked into #{kind}")
end

# A complete, naturally dealt challenge through action_for and replay. Find
# a legal sequence with a large score gap; do not edit scores or race state.
h = Harness.new(kind: 'numbered_balls')
h.open_round
id = h.begin_round
initial = h.replay.state[:round][:engine]
first = ENGINE.current_turn(initial)
balls = ENGINE.view(initial, seat: first).fetch(:remaining)
find_picks = lambda do |remaining, scores, turn|
  return (scores[0] - scores[1]).abs > 10 ? [] : nil if remaining.empty?
  (1..[3, remaining.length].min).each do |count|
    updated = scores.dup
    updated[turn] += remaining.first(count).sum
    rest = find_picks.call(remaining.drop(count), updated, 1 - turn)
    return [count] + rest if rest
  end
  nil
end
picks = find_picks.call(balls, [0, 0], first)
assert(picks, 'The natural fixture must allow a score difference above ten')
totals, presses = [0, 0], [0, 0]
picks.each do |count|
  current = h.replay.state[:round][:engine]
  seat = ENGINE.current_turn(current)
  totals[seat] += ENGINE.view(current, seat: seat).fetch(:remaining).first(count).sum
  presses[seat] += 1
  h.accept({'action' => 'input', 'challenge' => id,
    'input' => {'kind' => 'take', 'value' => count, 'press_id' => presses[seat]}}, actor: h.players[seat])
end
result = h.replay.state[:last_resolution][:settlement]
assert((totals[0] - totals[1]).abs > 10)
assert_equal(totals[0] > totals[1] ? 0 : 1, result.winner)
assert_equal([10], result.transfers.map(&:amount))
assert_equal(nil, h.replay.state[:round])
assert_equal(DuckGameAdapterTest.semantic(result), DuckGameAdapterTest.semantic(h.replay.state[:last_resolution][:settlement]))
puts 'PASS numbered balls ten-feather cap, ties, signed scores, limited funds, other stakes and complete replay'
