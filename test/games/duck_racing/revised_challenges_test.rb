require_relative '../../support/duck_game_adapter'
require_relative '../../../games/duck_racing_support/challenge_presentation'

include DuckGameAdapterTest
results = []
check = lambda do |name, &block|
  block.call
  results << {name: name, status: 'PASS'}
rescue StandardError => error
  results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", trace: error.backtrace.first(4)}
end

%w[copy_number arithmetic race_question count_ducks].each do |kind|
  check.call("#{kind}: first correct accepted answer ends the challenge for all three players") do
    h = Harness.new(kind: kind, count: 3)
    challenge = h.open_round
    h.begin_round
    trace = LOGIC::ChallengeTrace.new(challenge, seat: 1, resources: h.resources)
    if kind == 'count_ducks'
      stimulus = LOGIC::ChallengeEngine.stimulus(trace.state, seat: 1)
      assert(trace.submit({kind: :playback_finished, playback_id: stimulus[:id]}, at: 10_000))
    end
    answer = LOGIC::ChallengeEngine.solution(challenge, resources: h.resources)
    assert(trace.submit({kind: :answer, value: kind == 'count_ducks' ? answer : answer.to_s, press_id: 1}, at: 11_000))
    h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot}, actor: 'Bob')
    resolution = h.replay.state[:last_resolution]
    assert(resolution, 'Still waiting for the other players')
    assert_equal(1, resolution[:settlement].winner)
    assert_equal([[0, 1, 4], [2, 1, 4]], resolution[:settlement].transfers.map { |t| [t.from, t.to, t.amount] })
    assert_equal(answer, resolution[:answer])
    assert_equal('attempt', h.decode.last[0]['action'])
    assert_equal([:invalid, nil], h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot}, actor: 'Bob'))
  end
end

check.call('guess number: two minutes and equal distance is a draw regardless of attempts or time') do
  model = LOGIC::NumericChallenges.start('guess_number', seats: [0, 1], seed: 7, now_ms: 0)
  assert_equal(120_000, model[:deadline_ms])
  answer = model[:answer]
  wrong = answer == 1 ? 2 : 1
  assert(LOGIC::NumericChallenges.submit(model, seat: 0, action: {kind: :answer, value: wrong, press_id: 1}, now_ms: 20))
  assert(LOGIC::NumericChallenges.submit(model, seat: 0, action: {kind: :answer, value: answer, press_id: 2}, now_ms: 30))
  assert(LOGIC::NumericChallenges.submit(model, seat: 1, action: {kind: :answer, value: answer, press_id: 1}, now_ms: 119_999))
  assert_equal(nil, model[:outcome][:winner])
  results_by_seat = model[:players].transform_values { |p| {best: p[:best], attempts: p[:attempts].length} }
  assert_equal(nil, LOGIC::ChallengeEngine.settlement('guess_number', balances: {0 => 10, 1 => 10}, results: results_by_seat).winner)
end

check.call('numbered balls: one minute each, public values and next turn') do
  model = LOGIC::NumericChallenges.start('numbered_balls', seats: [0, 1], seed: 7, now_ms: 100)
  assert_equal(60_100, model[:deadline_ms])
  seat = model[:participants][model[:turn_index]]
  values = model[:remaining].first(3)
  assert(LOGIC::NumericChallenges.submit(model, seat: seat, action: {kind: :take, value: 3, press_id: 1}, now_ms: 60_099))
  assert_equal(120_099, model[:deadline_ms])
  assert_equal([[:challenge_take, seat, values], [:challenge_turn, 1 - seat]], model[:notices])
end

check.call('blackjack: no second automatic announcement of own initial hand') do
  model = challenge_state('blackjack')
  view = LOGIC::ChallengeEngine.view(model, seat: 0)
  prompt = LOGIC::ChallengePresentation.project(kind: 'blackjack', view: view, viewer: 0)
  assert(!prompt[:announcement].include?('Cards:'), prompt[:announcement])
  assert(prompt[:header].include?('Cards:'), 'The hand was removed from manual inspection')
end

check.call('single die history does not repeat its total; risky dice retains it') do
  %w[dice_duel risky_dice].each do |kind|
    h = Harness.new(kind: kind)
    h.open_round
    id = h.begin_round
    seat = LOGIC::ChallengeEngine.current_turn(h.replay.state[:round][:engine])
    h.accept({'action' => 'input', 'challenge' => id, 'input' => {'kind' => 'roll', 'press_id' => 1}}, actor: h.players[seat])
    text = h.replay.history.find { |e| e.kind == :challenge_roll }.text
    assert_equal(kind == 'risky_dice', text.include?('Total:'), text)
  end
  assert(LOGIC::ChallengePresentation.description('risky_dice')[1].include?('25'))
end

check.call('word challenges are not selectable') do
  assert_equal([], LOGIC::Challenges::BY_ID.keys & %w[anagram longest_word])
  assert_equal(18, LOGIC::Challenges::BY_ID.size)
end

check.call('zero-feather loser freezes before a queued challenge, even with no payable transfer') do
  # Controlled model boundary: the next destination effect is already queued.
  # Do not let it open another duel before freezing the just-defeated duck.
  state = LOGIC::Race.start(player_count: 3, laps: 3, enabled_challenges: ['copy_number'], seed: 7)
  state[:racers][0][:feathers] = 0
  state[:phase] = :challenge
  state[:challenge] = {id: 77, participants: [0, 1]}
  state[:pending] = [[:effect, 0, 0, [:group_challenge]]]
  result = LOGIC::Settlement.fixed(balances: {0 => 0, 1 => 10}, winner: 1, amount: 4)
  assert_equal([], result.transfers)
  assert(LOGIC::Race.new(state).complete_challenge(id: 77, result: result))
  assert(state[:racers][0][:frozen_turns].positive?, 'Zero balance did not freeze before the next challenge')
  assert_equal([1, 2], state[:challenge][:participants])
  assert_equal(1, state[:notices].count { |notice| notice.first == :frozen })
end

puts JSON.pretty_generate(results)
raise 'Revised challenge regressions failed' unless results.all? { |r| r[:status] == 'PASS' }
