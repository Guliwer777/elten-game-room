require_relative 'bots_helpers'

include GameRoomTest::Assertions
logic = GameRoomDuckRacing
engine = logic::ChallengeEngine
checks = 0
def actions(fixture)
  repository = Object.new
  def repository.actor_of(event, _session); event['actor']; end
  result = []
  GameRoomActionPayload.each(fixture.events, 'duck_racing', repository, {}) { |data, _actor, _batch| result << data['action'] }
  result
end

# Every challenge uses the real action planning boundary; old fixtures retain
# their legacy start records and are tested separately by session_test.
logic::Challenges::TYPES.each do |type|
  fixture = DuckBotFixture::Fixture.new(kind: type.id, flow: 2)
  fixture.challenge
  round = fixture.state.fetch(:round)
  assert_equal(:playing, round[:phase])
  count = actions(fixture).length
  prepared = []
  case type.id
  when *engine::LOCAL_SCORES, *engine::COMPACT_PRIVATE
    challenge = round[:challenge]
    plans = [0, 1].map do |seat|
      logic::ChallengeBot.plan(challenge, seat: seat, seed: 90, resources: DuckBotFixture.resources, compact: true)
    end
    at = round[:started_at] + plans.map(&:last).max + 1
    fixture.alive(at: at - 1) if at - round[:started_at] >= 30_000
    before_answers = actions(fixture).length
    [0, 1].each do |seat|
      answer = plans[seat].first
      assert(!answer.key?('actions'), 'Compact submission still contains key events')
      assert(JSON.generate(answer).bytesize < 120, 'Compact answer grew with the input trace')
      fixture.apply({'kind' => 'duck', 'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => answer}, seat: seat, at: at)
      if engine::LOCAL_SCORES.include?(type.id) && seat == 0
        assert_equal([0], fixture.state[:round][:results].keys)
        assert(!logic::Session.idle?(fixture.state[:round], at + 1))
        candidate = logic::Session.copy(fixture.state)
        assert_equal(false, logic::Session.apply(candidate, {'action' => 'result', 'challenge' => challenge[:id],
          'answer' => answer}, seat: seat, moderator: false, now_ms: at))
        stored = logic::LocalResult.recover(fixture.state, seat: seat, user: fixture.players[seat], vault: fixture.vault)
        assert_equal(answer, stored, 'Uncertain result is not recoverable')
      end
    end
    if engine::COMPACT_PRIVATE.include?(type.id)
      assert_equal(:revealing, fixture.state[:round][:private][:phase], 'Last commit did not open reveal immediately')
      assert_equal({}, fixture.state[:round][:private][:reveals], 'An answer leaked before all commits')
      [1, 0].each do |seat|
        request = fixture.game.automatic_action(fixture.replay, fixture.players[seat], context: fixture.context(at + 1))
        assert_equal('reveal', request && request['action'])
        fixture.apply(request, seat: seat, at: at + 1)
      end
    end
    assert_equal(challenge[:id], fixture.state[:last_resolution][:id])
    assert(!fixture.state[:last_resolution][:cancelled])
    expected = engine::LOCAL_SCORES.include?(type.id) ? 2 : 4
    assert_equal(expected, actions(fixture).length - before_answers, 'Unexpected extra answer writes')
    fixture.game.cleanup_session_answers(fixture.replay, session_id: 777, actors: fixture.players, hidden_submissions: fixture.vault)
    fixture.players.each { |user| assert_equal([], fixture.vault.envelopes(session_id: 777, user: user, round_prefix: 'duck')) }
  when *engine::FIRST_ANSWER
    assert(round[:response_at] > round[:started_at], 'First-answer challenge has no common boundary')
    trace = logic::ChallengeBot.plan(round[:challenge], seat: 0, seed: 1, resources: DuckBotFixture.resources)
    status, = fixture.game.action_for({'kind' => 'duck', 'action' => 'submit_trace', 'challenge' => round[:challenge][:id],
      'trace' => trace}, fixture.replay, fixture.players[0], context: fixture.context(round[:response_at] - 1))
    assert_equal(:invalid, status, 'First-answer attempt accepted before the common start')
    fixture.apply({'kind' => 'duck', 'action' => 'submit_trace', 'challenge' => round[:challenge][:id], 'trace' => trace},
      at: round[:response_at] + trace['finished_at'])
  when *engine::SHARED
    assert(round[:engine], 'Public turns lost their shared model')
    assert_equal([0, 1], round[:ready].keys)
  when *engine::REALTIME
    assert_equal([0, 1], round[:ready].keys)
    assert_equal(nil, round[:engine])
  end
  if engine::INDEPENDENT.include?(type.id)
    assert_equal(0, round[:ready].length, 'Independent attempt still requires a network ready')
  else
    assert_equal(3, count, 'Shared start still writes an extra begin event')
  end
  checks += 1
end

# Compact numeric guesses retain the same score without trusting a claimed
# distance. Malformed or excessive guesses are rejected, not truncated.
fixture = DuckBotFixture::Fixture.new(kind: 'guess_number', flow: 2)
fixture.challenge
challenge = fixture.state[:round][:challenge]
trace = logic::ChallengeBot.plan(challenge, seat: 0, seed: 90, resources: DuckBotFixture.resources)
compact, = logic::ChallengeBot.plan(challenge, seat: 0, seed: 90, resources: DuckBotFixture.resources, compact: true)
old = logic::TraceVerifier.new(challenge: challenge, balances: {0 => 18, 1 => 18}, resources: DuckBotFixture.resources)
old_result = old.replay(traces: {0 => trace}, forfeits: [1]).results[0]
assert_equal(old_result, logic::CompactAttempt.verify(challenge, compact, seat: 0, resources: DuckBotFixture.resources))
begin
  logic::CompactAttempt.verify(challenge, {'guesses' => [1] * 11}, seat: 0)
  raise 'Accepted eleven guesses'
rescue logic::TraceVerifier::InvalidTrace
end
puts "PASS streamlined flow for #{checks} challenge types, compact payloads, barriers, duplicate results and cleanup"
