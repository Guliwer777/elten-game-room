require_relative '../support/pong_client'
require_relative '../support/session_runner'
require_relative '../support/tournament_individual_execution'
require_relative '../../lib/tournaments/realtime_match_client'
require_relative '../../lib/tournaments/game_result'
include TournamentIndividualExecutionSupport

with_fixture(game: 'axel_pong', names: %w[Alice Bob], rematch: false, game_options: {'target' => 7}) do |fixture|
  backend = fixture.backend
  base = fixture.base.transform_values(&:reverse)
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: base, intent_id: 'realtime-runner-input'))
  match = record['evidence']['plan']['matches'].first
  selectors = {evidence: record['evidence'], expected_source: record['expected_source'],
    match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'], registry: fixture.registry}
  request = T::CoordinationRequest.from_execution_plan(**selectors)
  native = T::IndividualNativePayload.from_execution_plan(**selectors)
  room = NativeRoomHarness.new(game: fixture.registry.build('axel_pong'), users: native.to_h['players'], options: native.to_h['options'])
  room.start
  runner = runner_for(room, 'Alice')
  step(room, runner)
  projection = runner.presentation_snapshot
  h = PongHarness.new(players: native.to_h['players'], session: projection.session,
    session_id: projection.session['__id'], table_id: projection.table['__id'])
  snapshot = -> do
    value = runner.presentation_snapshot
    {table: value.table, session: value.session, replay: value.replay}
  end
  bridge = T::RealtimeMatchClient.new(program: h.programs['Alice'], request: request, native: native,
    registry: fixture.registry, viewer: 'Alice', snapshot: snapshot,
    services: {clock: -> { h.now }, audio: PongTestAudio.new,
      channel_factory: ->(**args) { PongTestChannel.new(h.network, **args) }})
  begin
    h.clients['Alice'].close
    assert(bridge.start, 'The accepted match must bind to the ordinary native session')
    h.clients['Alice'] = bridge.instance_variable_get(:@client)
    bridge.attach_view(Form.new([]), h.surfaces['Alice'])
    h.advance(220)
    assert_equal(nil, bridge.publish_agreed_input(runner: runner))
    step(room, runner, count: 2)
    assert_equal(0, room.events('Alice').size)
    if h.players[h.clients['Alice'].engine.server] == 'Alice'
      h.surfaces['Bob'].controls['move'] = 1
      h.press('Alice')
    else
      assert(h.clients['Alice'].request_hurry, 'The current opposing server must be hurriable')
    end
    1600.times do
      h.advance(1)
      break if h.clients['Alice'].context_data['pong_point']
    end
    input = bridge.publish_agreed_input(runner: runner)
    assert(input, 'Only an agreed client goal can be published to the Runner')
    step(room, runner, count: 3)
    assert_equal(1, room.events('Alice').size)
    fresh = runner.presentation_snapshot.replay
    h.instance_variable_set(:@replay, fresh)
    h.clients.each { |name, client| client.before_wait(fresh, name) }
    h.surfaces['Bob'].controls['move'] = 0
    6.times do |index|
      h.advance(380)
      if h.players[h.clients['Alice'].engine.server] == 'Alice'
        h.surfaces['Bob'].controls['move'] = 1
        h.press('Alice')
      else
        assert(h.clients['Alice'].request_hurry, 'Only the opposing participant may hurry the current server')
      end
      1600.times do
        h.advance(1)
        break if h.clients['Alice'].context_data['pong_point']
      end
      point = bridge.publish_agreed_input(runner: runner)
      assert(point, 'The next real client goal must be agreed')
      step(room, runner, count: 3)
      assert_equal(index + 2, room.events('Alice').size)
      fresh = runner.presentation_snapshot.replay
      h.instance_variable_set(:@replay, fresh)
      h.clients.each { |name, client| client.before_wait(fresh, name) }
      h.surfaces['Bob'].controls['move'] = 0
      assert_equal(nil, bridge.publish_agreed_input(runner: runner))
      step(room, runner, count: 2)
      assert_equal(index + 2, room.events('Alice').size)
    end
    room.assert_converged('full real Pong match through one shared Runner', expected_count: 7)
    final = room.replay('Alice')
    assert(final.finished? && final.winner == 'Alice', 'Native accepted history must finish the actual game')
    result = T::GameResult.from_replay(game: room.game, replay: final, players: request.to_h['players'],
      options: native.to_h['options'], event_count: 7, result_policy: T::GameResult::CURRENT_RESULT_POLICY)
    assert_equal({'alice' => 7, 'bob' => 0}, result['scores'])
    assert_equal(['alice'], result['winners'])
    assert_equal(input['local_data']['pong_point'], room.events('Alice').first['value'])
    bridge.refresh
    assert_equal(nil, bridge.publish_agreed_input(runner: runner))
    step(room, runner, count: 3)
    assert_equal(7, room.events('Alice').size)
    other = NativeRoomHarness.new(game: room.game, users: native.to_h['players'], options: native.to_h['options'])
    other.start
    other_runner = runner_for(other, 'Alice')
    begin
      step(other, other_runner)
      failure = assert_raises(T::Publication::Invalid) { bridge.publish_agreed_input(runner: other_runner) }
      assert_equal(:native_target_mismatch, failure.code)
      assert_equal(0, other.events('Alice').size)
    ensure
      other_runner.close
    end
  ensure
    bridge.close
    runner.close
    h.close
  end
end
puts 'PASS accepted-plan full Pong match through one ordinary Runner/native LiveSessions: seven real client-agreed points, all players converge, correct 7:0 tournament result, no duplicate or wrong-target writes; isolated native/peer transport'
