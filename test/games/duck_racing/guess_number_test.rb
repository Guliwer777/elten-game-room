# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative '../../../games/duck_racing_support/numeric_bot'

include DuckGameAdapterTest
settlement = LOGIC::Settlement
engine = LOGIC::NumericChallenges
balances = {0 => 20, 1 => 20}.freeze

# Independent, explicit expectations at every band boundary, including the
# original 47/48 report. The scale follows the target, not either guess.
cases = [
  [1, 0, 1, 1], [1, 0, 2, 2], [1, 0, 3, 2], [1, 0, 4, 3],
  [1, 0, 5, 4], [1, 0, 6, 4], [1, 0, 7, 5], [1, 0, 8, 5],
  [9, 0, 8, 5], [9, 0, 50, 5], [47, 0, 1, 1],
  [10, 0, 10, 1], [90, 0, 10, 1], [91, 0, 31, 4],
  [47, 1, 11, 1], [47, 1, 12, 2], [99, 0, 11, 2],
  [99, 0, 20, 2], [99, 0, 21, 3], [99, 0, 30, 3],
  [99, 0, 31, 4], [99, 0, 40, 4], [99, 0, 41, 5],
  [99, 0, 50, 5], [99, 0, 900, 5],
  [100, 0, 1, 1], [100, 0, 100, 1], [100, 0, 101, 2],
  [500, 0, 200, 2], [500, 0, 201, 3], [500, 0, 300, 3],
  [999, 0, 301, 4], [999, 0, 400, 4], [999, 0, 401, 5],
  [999, 0, 500, 5], [999, 0, 501, 5], [999, 0, 998, 5],
  [500, 49, 149, 1], [500, 49, 150, 2]
]
cases.each do |target, best, other, fee|
  distances = {0 => best, 1 => other}.freeze
  result = settlement.guess_number(balances: balances, target: target, distances: distances)
  assert_equal(0, result.winner)
  assert_equal([[1, 0, fee]], result.transfers.map { |t| [t.from, t.to, t.amount] }, "target #{target}: #{distances}")
  assert_equal({0 => 20 + fee, 1 => 20 - fee}, result.balances)
  assert_equal(40, result.balances.values.sum)
  assert(result.frozen? && result.balances.frozen? && result.transfers.frozen?)
end

[{0 => 0, 1 => 0}, {0 => 1, 1 => 1}].each do |distances|
  result = settlement.guess_number(balances: balances, target: 47, distances: distances)
  assert_equal(:draw, result.outcome)
  assert_equal(balances, result.balances)
  assert_equal([], result.transfers)
end
none = settlement.guess_number(balances: balances, target: 100, distances: {0 => nil, 1 => nil})
assert_equal(:no_winner, none.outcome)
assert_equal(balances, none.balances)
missing = settlement.guess_number(balances: balances, target: 100, distances: {0 => 20, 1 => nil})
assert_equal({0 => 25, 1 => 15}, missing.balances)
excluded = settlement.guess_number(balances: balances, target: 100, distances: {0 => 20, 1 => 0}, eligible: [0])
assert_equal({0 => 25, 1 => 15}, excluded.balances)
assert_equal(:no_winner, settlement.guess_number(balances: balances, target: 100,
  distances: {0 => 0, 1 => 1}, eligible: []).outcome)
multi = settlement.guess_number(balances: {0 => 0, 1 => 1, 2 => 20, 3 => 0}, target: 500,
  distances: {0 => 10, 1 => 211, 2 => 111, 3 => nil})
assert_equal({0 => 3, 1 => 0, 2 => 18, 3 => 0}, multi.balances)
assert_equal([[1, 0, 1], [2, 0, 2]], multi.transfers.map { |t| [t.from, t.to, t.amount] })
[nil, 0, 1_000, 1.5, '100'].each do |invalid|
  assert_raises(ArgumentError) { settlement.guess_number(balances: balances, target: invalid, distances: {0 => 0, 1 => 1}) }
end
[-1, 999, 1.5, '1'].each do |invalid|
  assert_raises(ArgumentError) { settlement.guess_number(balances: balances, target: 50, distances: {0 => 0, 1 => invalid}) }
end

# Find natural deterministic draws throughout the enlarged range. No model
# answer is overwritten. A public-view-only bot can find every target in ten
# guesses; neither its view nor the UI leaks the exact answer or distances.
seeds = {}
50_000.times do |seed|
  model = engine.start('guess_number', seats: [0, 1], seed: seed, now_ms: 0)
  answer = model.fetch(:answer)
  assert(answer.between?(1, 999))
  seeds[answer] ||= seed
  break if seeds.size == 999
end
assert_equal((1..999).to_a, seeds.keys.sort, 'Some possible targets were never generated')
seeds.each do |answer, seed|
  model = engine.start('guess_number', seats: [0, 1], seed: seed, now_ms: 0)
  random = Random.new(seed)
  10.times do |index|
    view = engine.public_view(model, viewer: 0)
    assert_equal(answer.to_s.length, view[:answer_digits])
    assert(!view.key?(:answer) && !view[:own].key?(:best))
    assert(view[:own][:attempts].none? { |attempt| attempt.key?(:distance) })
    action = LOGIC::NumericBot.choose(view, seat: 0, random: random)
    assert(action, "Bot stopped before finding #{answer}")
    assert(engine.submit(model, seat: 0, action: action.merge(press_id: index + 1), now_ms: index * 1_300))
    break if model[:players][0][:done]
  end
  assert_equal(:correct, model[:players][0][:status], "Bot failed to find #{answer}")
end

# Private traces are replayed before the authoritative target chooses a band.
# Include non-exact winners, opposite-side ties and best-not-last guesses.
[[1, [1], [9], 5], [47, [47], [48], 1], [47, [46, 10], [35], 2],
 [47, [46], [48], nil], [91, [91], [60], 4],
 [100, [100], [201], 2], [999, [999], [498], 5]].each do |target, first, second, fee|
  challenge = {id: 1, kind: 'guess_number', participants: [0, 1], seed: seeds.fetch(target),
    race_snapshot: {racers: {0 => {die_sides: 6, die_rolls: 0}, 1 => {die_sides: 6, die_rolls: 0}}}}
  traces = [first, second].each_with_index.to_h do |guesses, seat|
    trace = LOGIC::ChallengeTrace.new(challenge, seat: seat)
    guesses.each_with_index do |guess, index|
      assert(trace.submit({kind: :answer, value: guess, press_id: index + 1}, at: 100 + index))
    end
    trace.tick(at: 120_000) unless trace.finished?
    assert(!LOGIC::ChallengeEngine.view(trace.state, seat: seat).key?(:answer))
    [seat, trace.snapshot]
  end
  verifier = LOGIC::TraceVerifier.new(challenge: challenge, balances: balances)
  result = verifier.replay(traces: traces, forfeits: []).settlement
  assert_equal(fee ? [[1, 0, fee]] : [], result.transfers.map { |t| [t.from, t.to, t.amount] })
  assert_equal(result, verifier.replay(traces: traces.to_a.reverse.to_h, forfeits: []).settlement)
end

# Complete the actual action/commit/reveal/replay path for multiple players.
[2, 3, 8].each do |count|
  harness = Harness.new(count: count)
  harness.open_round
  harness.begin_round
  harness.finish_private
  replay = harness.replay
  result = replay.state[:last_resolution][:settlement]
  assert_equal(0, result.winner)
  assert_equal(count - 1, result.transfers.length)
  assert(result.transfers.all? { |transfer| transfer.amount == 1 })
  assert_equal(18 * count, result.balances.values.sum)
  assert_equal(DuckGameAdapterTest.semantic(replay), DuckGameAdapterTest.semantic(harness.replay))
end

puts 'PASS guessing scales/boundaries, 999 targets and bots, private trace verification, 2/3/8-player action replay'
