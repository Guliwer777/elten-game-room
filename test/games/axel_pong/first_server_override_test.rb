require_relative "../../support/audio_ball_client"
require_relative "../../support/assertions"

class PongFirstServerOverrideTest
  include GameRoomTest::Assertions

  def assert(value, message = "Assertion failed")
    @checks = (@checks || 0) + 1
    super
  end

  def replay(players, options)
    game = GameRoomGames::AxelPong.new
    repository = Object.new
    def repository.players_for(session); session['__players']; end
    def repository.actor_of(event, _session); event['actor']; end
    def repository.event_id(event); event['__id']; end
    session = {'__players' => players, '__insertion_user' => 'Alice', 'player_one' => players.first,
      'options' => JSON.generate(game.default_options.merge(options))}
    [game, game.replay(session, [], repository)]
  end

  def run
    bot = GameRoomParticipants.bot_id(20, 1)
    configurations = [
      [%w[Alice Bob], {}], [[bot, 'Alice'], {}], [['Alice', bot], {}],
      [%w[Alice Bob Carol Dave], {'team_size' => 2, 'team_seats' => [0, 0, 1, 1]}],
      [['Alice', bot, 'Carol', 'Dave'], {'team_size' => 2, 'team_seats' => [0, 0, 1, 1]}]
    ]
    configurations.each do |players, options|
      game, state = replay(players, options)
      [nil, 0, 1].each do |choice|
        network, clients, now = {}, [], 0.0
        viewers = (['Alice'] + players.reject { |name| GameRoomParticipants.bot?(name) } + ['Watcher']).uniq
        begin
          viewers.each do |viewer|
            client = GameRoomPong::Client.new(Program.new, game, clock: -> { now }, audio: PongTestAudio.new,
              channel_factory: ->(**args) { AudioBallTestChannel.new(network, **args) })
            client.bind_screen(session_id: 300, table_id: 20, owner: 'Alice', viewer: viewer,
              members: -> { viewers }, first_server: choice)
            clients << client
            client.before_wait(state, viewer)
          end
          legacy_hash = Digest::SHA256.hexdigest('GameRoom:axel_pong:20:300')[0, 24]
          expected = if choice != nil
            choice
          elsif players.length == 2 && players.any? { |name| GameRoomParticipants.bot?(name) }
            players.index { |name| !GameRoomParticipants.bot?(name) } || 0
          else
            legacy_hash[-1].to_i(16) % 2
          end
          teams = players.length == 4 ? [0, 0, 1, 1] : [0, 1]
          rotation = GameRoomPong::Rotation.new(teams: teams, rally: 0, first_server: expected)
          clients.each do |client|
            assert_equal(legacy_hash, client.instance_variable_get(:@match), "An explicit server changed channel identity")
            assert_equal(expected, client.send(:first_server))
            assert_equal(rotation.server, client.engine.server)
            assert_equal(rotation.receiver, client.send(:rally_state).rotation.receiver)
            client.update_table_control('__control_epoch' => 'initial', '__table_owner' => 'Alice', '__initial_players' => players)
            client.update_table_control('__control_epoch' => 'changed', '__table_owner' => 'Watcher', '__initial_players' => players)
            client.before_wait(state, client.instance_variable_get(:@viewer))
            assert_equal(expected, client.send(:first_server), "Control replacement changed the first server")
            assert_equal(rotation.server, client.engine.server)
          end
        ensure
          clients.each(&:close)
        end
      end
    end

    # A scoped single challenge can start with its bot on either side. This
    # exercises actual bot serve progression, not just a reported selection.
    [[bot, 'Alice', 0], ['Alice', bot, 1]].each do |left, right, server|
      game, state = replay([left, right], {})
      now, network, activities = 0.0, {}, []
      transport = Object.new
      transport.define_singleton_method(:note_realtime_activity) { |table, session| activities << [table, session] }
      client = GameRoomPong::Client.new(Program.new, game, clock: -> { now }, audio: PongTestAudio.new,
        transport: transport, channel_factory: ->(**args) { AudioBallTestChannel.new(network, **args) })
      begin
        client.bind_screen(session_id: 300, table_id: 20, owner: 'Alice', viewer: 'Alice',
          members: -> { ['Alice'] }, match_scope: "bot-first-#{server}", first_server: server)
        client.start
        client.before_wait(state, 'Alice')
        220.times { now += 0.016; client.frame }
        assert(client.engine.turn > 0, "Configured bot did not actually serve")
        assert(!activities.empty?, "The scoped bot serve did not report activity")
        assert(activities.all? { |entry| entry == [20, 300] }, "Activity used a synthetic session ID")
      ensure
        client.close
      end
    end

    [-1, 2, 0.0, 1.0, '0', false, [], {}].each do |choice|
      calls = []
      client = GameRoomPong::Client.new(Program.new, GameRoomGames::AxelPong.new, audio: PongTestAudio.new,
        channel_factory: ->(**args) { calls << args })
      assert_raises(ArgumentError) do
        client.bind_screen(session_id: 300, table_id: 20, owner: 'Alice', viewer: 'Alice',
          members: -> { [] }, first_server: choice)
      end
      assert_equal([], calls)
      assert_equal(false, client.instance_variable_defined?(:@activity_session))
      client.close
    end
    puts "PASS Pong optional first server: #{@checks} checks"
  end
end

PongFirstServerOverrideTest.new.run
