require_relative 'bots_helpers'

# Pure planning and ordinary action validation; runner writes are checked in
# bot_runner_test, not by calling a retired or duplicate scheduler.
include DuckBotFixture
checks = 0
kinds = LOGIC::ChallengeBot::PRIVATE_TYPES + LOGIC::ChallengeEngine::SHARED
kinds.each do |kind|
  h = Fixture.new(kind: kind)
  h.challenge
  round = h.state[:round]
  seat = round[:engine] ? (LOGIC::ChallengeEngine.current_turn(round[:engine]) || 0) : 0
  actor = h.players[seat]
  plans = [0, 1, 3, 5].to_h do |delay|
    h.state[:options]['bot_delay'] = delay
    snapshot = Marshal.dump(h.state)
    game = DuckBotFixture.game
    value = game.plan_duck_bot(h.replay, actor, context: h.context(1_200))
    assert(value, "Missing #{kind} bot plan")
    assert_equal(snapshot, Marshal.dump(h.state), 'Planning changed accepted state')
    assert_equal(value, game.plan_duck_bot(h.replay, actor, context: h.context(1_201)))
    assert(!game.duck_bot_ready?(value, h.replay, h.context(value[:ready_ms] - 1)))
    assert(game.duck_bot_ready?(value, h.replay, h.context(value[:ready_ms])))
    if value[:trace]
      verifier = LOGIC::TraceVerifier.new(challenge: round[:challenge], balances: round[:balances], resources: DuckBotFixture.resources)
      if LOGIC::ChallengeEngine::FIRST_ANSWER.include?(kind)
        verifier.verify_attempt(seat, value[:trace])
      else
        verifier.replay(traces: {seat => value[:trace]}, forfeits: round[:challenge][:participants] - [seat])
      end
    end
    [delay, value]
  end
  times = plans.values.map { |value| value[:ready_ms] }
  assert(times[1] > times[0] && times.each_cons(2).all? { |first, second| second >= first },
    "#{kind}: bot_delay was ignored: #{times.inspect}")
  if kind == 'rhythm'
    inputs = plans.values.map { |value| value[:trace]['actions'].select { |entry| entry['input']['kind'] == 'tone' } }
    intervals = inputs.map { |entries| entries.each_cons(2).map { |first, second| second['at'] - first['at'] } }
    assert_equal([intervals.first] * 4, intervals, 'Bot delay must not stretch the rhythm itself')
  end
  checks += 1
end

# The same planning cache must not return a trace for an old delay setting.
h = Fixture.new(kind: 'quiz')
h.challenge
actor = h.players.first
first = h.game.plan_duck_bot(h.replay, actor, context: h.context(1_200))
h.state[:options]['bot_delay'] = 3
second = h.game.plan_duck_bot(h.replay, actor, context: h.context(1_200))
assert_equal(3_000, second[:ready_ms] - first[:ready_ms])
puts "PASS Duck configured bot delay: #{checks} challenge types, 0/1/3/5 seconds, traces and cache isolation"
