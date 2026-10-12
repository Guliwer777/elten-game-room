require_relative 'client_helpers'
require_relative '../../support/duck_game_adapter'
require_relative '../../support/session_runner'

class DuckPacingClientTest
  include DuckClientTest

  def run
    [false, true].each do |background|
      busy = true
      setup_client('copy_number', presentation_busy: -> { busy })
      assert_equal(nil, @client.local_view, 'A challenge appeared during the race pause')
      assert_equal(false, @client.context_data['duck_ready'])
      assert_equal(0, @game.loads, 'Preparation started before the preceding race messages')
      advance(1_000, background: background)
      assert_equal([], @program.events)
      assert_equal(nil, request)
      busy = false
      advance(2_000, background: background)
      assert_equal(1, @game.loads)
      assert_equal(2_000, @client.instance_variable_get(:@origin_ms), 'Attempt time included the preceding race pause')
      assert(@client.local_view)
      assert(@client.local_view[:preparing], 'The race pause consumed the speed challenge preparation')
      advance(2_100, background: background)
      assert_equal(1, @game.loads, 'Deferred activation repeated resource loading')
      trace = @client.instance_variable_get(:@trace)
      busy = true
      previous = @replay
      replace
      assert_equal(false, @client.before_wait(previous, @viewer), 'A stale view replaced the latest deferred replay')
      assert_equal(nil, request)
      busy = false
      advance(2_200, background: background)
      assert_equal(trace, @client.instance_variable_get(:@trace), 'A same-challenge refresh restarted the attempt')
      busy = true
      replace
      close
      busy = false
      advance(3_000, background: background)
      assert_equal({}, @client.context_data, 'A closed client resumed its deferred view')
      assert_equal(1, @game.loads)
    end
    %w[axel_pong audio_ball].each do |kind|
      busy = false
      setup_client(kind, presentation_busy: -> { busy })
      native = @wrappers.last
      assert(native.active?, 'The native point did not start')
      busy = true
      replace do |replay|
        replay.state[:point_receipt] = {'id' => 1}
        replay.state[:round] = nil
        replay.state[:race][:phase] = :turn
      end
      assert(native.finishing?, 'The result pause delayed the native goal recording')
      advance(200, background: true)
      assert(!native.finishing?, 'The native goal stopped progressing during the result pause')
      assert_equal(nil, request)
      busy = false
      advance(2_000)
      assert_equal(nil, @client.local_view, 'A finished point remained on screen after the result pause')
      close
    end
    report('Duck client pacing: delayed activation, preparation, foreground/background, same attempt and close')
  ensure
    close
  end
end
DuckPacingClientTest.new.run

include GameRoomTest::Assertions
[false, true].each do |covered|
  fixture = DuckGameAdapterTest::Harness.new
  game = fixture.game
  seed = (1..100).find do |value|
    race = GameRoomDuckRacing::Race.start(player_count: 2, laps: 3, enabled_challenges: ['guess_number'], seed: value)
    GameRoomDuckRacing::Race.new(race).apply(seat: 0, revision: 0, action: {kind: :roll})
    race[:phase] == :turn
  end
  h = DuckGameAdapterTest::NativeHarness.new(game: game, users: ['Alice'], bots: 1,
    options: game.normalize_options({'challenges' => ['guess_number'], 'bot_delay' => 0}))
  h.start
  h.submit_at({'action' => 'start'}, actor: 'Alice', at: 100_000, seed: seed)
  h.submit_at({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice', at: 100_010)
  assert(GameRoomParticipants.bot?(h.replay('Alice').current_player), 'Fixture did not reach the bot turn')
  runner = runner_for(h, covered: -> { covered })
  context = GameRoomGames::ActionContext.new(local_data: {'duck_host' => true, 'duck_seat' => 0, 'duck_ready' => true})
  events = h.events('Alice').dup
  step(h, runner, count: 3)
  assert_equal(events, h.events('Alice'), 'A bot overtook an unpresented turn')
  runner.publish_view(session: h.session, replay: h.replay('Alice'), busy: true, context: context)
  step(h, runner, count: 3)
  assert_equal(events, h.events('Alice'), 'A bot ignored the foreground/background presentation pause')
  runner.publish_view(session: h.session, replay: h.replay('Alice'), busy: false, context: context)
  step(h, runner, count: 3)
  assert(h.events('Alice').length > events.length, 'The bot did not resume after the pause')
  assert(h.events('Alice').drop(events.length).all? { |event| GameRoomParticipants.bot?(event['actor']) },
    'Resuming a bot move impersonated a human')
  after = h.events('Alice').dup
  step(h, runner, count: 3)
  assert_equal(after, h.events('Alice'), 'The bot ran ahead before its next accepted view was presented')
  runner.close
end
puts 'PASS Duck runner pacing: real action/replay/bot writes wait for presentation in foreground and background'
