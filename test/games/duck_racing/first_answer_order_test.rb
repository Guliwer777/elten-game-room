require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

def answer_trace(h, seat, correct: true, at: 11_000)
  challenge = h.replay.state[:round][:challenge]
  trace = LOGIC::ChallengeTrace.new(challenge, seat: seat, resources: h.resources)
  if challenge[:kind] == 'count_ducks'
    cue = LOGIC::ChallengeEngine.stimulus(trace.state, seat: seat)
    assert(trace.submit({kind: :playback_finished, playback_id: cue[:id]}, at: 10_000))
  end
  answer = LOGIC::ChallengeEngine.solution(challenge, resources: h.resources)
  value = correct ? answer : answer.to_i + 1
  assert(trace.submit({kind: :answer, value: challenge[:kind] == 'count_ducks' ? value : value.to_s, press_id: 1}, at: at))
  trace.tick(at: 120_000) unless trace.finished?
  trace.snapshot
end

%w[copy_number arithmetic race_question count_ducks].each do |kind|
  [false, true].each do |reverse|
    h = Harness.new(kind: kind, count: 3)
    challenge = h.open_round
    h.begin_round
    snapshot = h.replay
    # Both plans were legal at the same revision. Arrival order, not the
    # clients' different local clocks, decides the first correct answer.
    plans = [0, 1].map do |seat|
      input = {'action' => 'submit_trace', 'challenge' => challenge[:id],
        'trace' => answer_trace(h, seat, at: seat.zero? ? 14_000 : 11_000)}
      context = h.context(h.players[seat])
      context.hidden_submissions = nil
      status, plan = h.game.action_for(input, snapshot, h.players[seat], context: context)
      assert_equal(:ok, status, 'First-answer submission unexpectedly needs a private vault')
      [seat, plan]
    end
    plans.reverse! if reverse
    first, second = plans
    h.append(first.last, actor: h.players[first.first])
    accepted = h.replay.accepted_events.dup
    resolution = h.replay.state[:last_resolution]
    assert_equal(first.first, resolution[:settlement].winner)
    assert_equal(8, resolution[:settlement].transfers.sum(&:amount))
    h.append(second.last, actor: h.players[second.first])
    assert_equal(accepted, h.replay.accepted_events, 'A late answer was accepted after resolution')
    assert_equal(resolution, h.replay.state[:last_resolution], 'Late answer changed the result')
    h.append(first.last, actor: h.players[first.first])
    assert_equal(resolution, h.replay.state[:last_resolution], 'Retry charged feathers twice')
    assert_equal(accepted, h.replay.accepted_events)
  end

  h = Harness.new(kind: kind)
  challenge = h.open_round
  h.begin_round
  wrong = answer_trace(h, 0, correct: false)
  h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => wrong}, actor: 'Alice')
  assert_equal(nil, h.replay.state[:last_resolution], 'One wrong answer prematurely ended the challenge')
  assert_equal(:invalid, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => wrong}, actor: 'Alice').first)
  h.owner = 'Bob'
  h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => answer_trace(h, 1)}, actor: 'Bob')
  assert_equal(1, h.replay.state[:last_resolution][:settlement].winner, 'Host change lost the challenge')

  h = Harness.new(kind: kind)
  challenge = h.open_round
  h.begin_round
  h.players.each_with_index do |actor, seat|
    h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id],
      'trace' => answer_trace(h, seat, correct: false)}, actor: actor)
  end
  result = h.replay.state[:last_resolution][:settlement]
  assert_equal(nil, result.winner)
  assert_equal([], result.transfers, 'Both wrong answers still charged feathers')
end

h = Harness.new(kind: 'copy_number', count: 3)
challenge = h.open_round(group: false)
h.begin_round
trace = answer_trace(h, 0)
baseline = DuckGameAdapterTest.semantic(h.replay)
bad_traces = [trace.merge('score' => 1), {'actions' => [], 'finished_at' => 1},
  {'actions' => [{'at' => 20, 'input' => {'kind' => 'answer', 'value' => 'abc', 'press_id' => 1}}], 'finished_at' => 20}]
bad_traces.each do |bad|
  assert_equal(:invalid, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => bad}, actor: 'Alice').first)
  assert_equal(baseline, DuckGameAdapterTest.semantic(h.replay), 'Rejected trace mutated the state')
end
assert_equal(:invalid, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace}, actor: 'Carol').first)
assert_equal(:not_your_turn, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace}, actor: 'Outsider').first)
assert_equal(:invalid, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id] + 1, 'trace' => trace}, actor: 'Alice').first)
h.replace(1, 'Replacement')
assert_equal(:participant_changed, h.replay.state[:last_resolution][:cancelled])
assert_equal(:invalid, h.plan({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace}, actor: 'Alice').first)
assert_equal([18, 18, 18], h.replay.state[:race][:racers].values.map { |racer| racer[:feathers] })
puts 'PASS first-answer order: 4 challenges, both arrival orders, late/retried answers, wrong answers, host transfer, validation and participant replacement'
