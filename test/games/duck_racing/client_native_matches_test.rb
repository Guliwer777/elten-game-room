require_relative 'realtime_helpers'
require_relative 'client_helpers'

class DuckClientNativeMatchesTest
  include DuckClientTest

  class PongSurface < PongTestSurface
    attr_accessor :on_pong_command
  end

  def run
    %w[axel_pong audio_ball].each do |kind|
      native_match(kind, %w[Host Alice Bob Watcher], [1, 2])
      native_match(kind, ['Host', 'Alice', '[BOT] Robin', 'Watcher'], [1, 2])
    end
    report('Duck client with real native single-point engines, outside host, bots, repetition and cancellation')
  end

  def native_match(kind, players, pair)
    @now, @network, @clients, @natives, @surfaces, @audios, @wrappers = 0.0, {}, {}, {}, {}, {}, {}
    @activity = []
    @viewers = players.reject { |name| GameRoomParticipants.bot?(name) }
    @replay = make_replay(kind, players: players, participants: pair)
    @replay.state[:owner] = 'Host'
    transport = Object.new
    transport.define_singleton_method(:game_action_limits) { |_table| {} }
    activity = @activity
    transport.define_singleton_method(:note_realtime_activity) { |table, session| activity << [table, session] }
    @viewers.each do |name|
      program = Program.new
      program.instance_variable_set(:@pong_preferences, GameRoomPong::Preferences.normalize('auto_return' => false))
      program.define_singleton_method(:pong_preferences) { @pong_preferences }
      game = Game.new(resources)
      client = CLIENT.new(program, game, clock: -> { @now }, transport: transport,
        session_time: ->(_state) { 100_000 + (@now * 1000).floor },
        progress_factory: ->(**_keywords, &block) { Progress.new(&block) },
        realtime_factory: -> {
          @wrappers[name] = GameRoomDuckRacing::RealtimeClient.new(program, clock: -> { @now }, transport: transport,
            client_factory: ->(native_kind, native_game, **options) {
              audio_type = native_kind == 'axel_pong' ? DuckPongTestAudio : DuckBallTestAudio
              @audios[name] = audio_type.new(clock: -> { @now })
              type = native_kind == 'axel_pong' ? GameRoomPong::Client : GameRoomAudioBall::Client
              @natives[name] = type.new(program, native_game, **options, audio: @audios[name],
                channel_factory: ->(**keywords) { AudioBallTestChannel.new(@network, **keywords) })
            })
        })
      client.bind_screen(session_id: 91, table_id: 18, owner: 'Host', viewer: name, members: -> { @viewers })
      client.start
      @clients[name] = client
      client.update_table_control(native_control)
      client.before_wait(@replay, name)
      attach_native(name, kind)
    end
    initial_match = @network.values.map(&:match).uniq
    assert_equal(1, initial_match.length)
    2.times do |index|
      receipt = complete_point(kind)
      assert_equal(index + 1, receipt['id'])
      assert_equal(pair, receipt['participants'])
      assert(pair.include?(receipt['winner']))
      assert(@clients.reject { |name, _| name == 'Host' }.values.all? { |client| client.context_data['duck_realtime_point'].nil? })
      @replay = Marshal.load(Marshal.dump(@replay))
      @replay.state[:revision] += 1
      @replay.state[:point_receipt] = receipt
      @replay.state[:last_resolution] = {id: receipt['id'], kind: kind}
      @replay.state[:round] = @replay.state[:race][:challenge] = nil
      @clients.each { |name, client| client.before_wait(@replay, name) }
      assert(@wrappers.values.all?(&:finishing?))
      assert(@network.values.none?(&:connected?))
      assert(@natives.values.all? { |client| client.instance_variable_get(:@replay).finished? })
      advance_native(20)
      assert(@wrappers.values.none?(&:active?))
      assert(@wrappers.values.none?(&:finishing?))
      assert(@clients.values.all? { |client| client.context_data['duck_realtime_point'].nil? })
      assert(@audios.values.all? { |audio| audio.calls.count { |call| call.first == :goal } == 1 })
      next_replay = make_replay(kind, id: index + 2, players: players, participants: pair)
      next_replay.state[:revision], next_replay.state[:owner] = @replay.state[:revision] + 1, 'Host'
      @replay = next_replay
      @clients.each do |name, client|
        client.before_wait(@replay, name)
        attach_native(name, kind)
      end
      assert(@network.values.map(&:match).none? { |match| initial_match.include?(match) })
    end
    assert(!@activity.empty?)
    assert(@activity.all? { |ids| ids == [18, 91] }, 'Native activity used a challenge ID instead of the real table/session')
    @replay = Marshal.load(Marshal.dump(@replay))
    @replay.state[:revision] += 1
    @replay.state[:last_resolution] = {id: 3, cancelled: :participant_changed}
    @replay.state[:round] = @replay.state[:race][:challenge] = nil
    @clients.each { |name, client| client.before_wait(@replay, name) }
    assert(@network.values.none?(&:connected?))
    assert(@wrappers.values.none?(&:active?))
    assert(@clients.values.all? { |client| client.context_data['duck_realtime_point'].nil? })
  ensure
    @clients&.each_value(&:close)
  end

  def native_control
    players = @replay.players
    {'__players' => players, '__initial_players' => players, '__table_owner' => 'Host', '__control_epoch' => 'initial',
      '__controllers' => players.to_h { |name| [name, GameRoomParticipants.bot?(name) ? 'bot' : name] }}
  end

  def attach_native(name, kind)
    @surfaces[name] = kind == 'axel_pong' ? PongSurface.new : AudioBallTestSurface.new
    @surfaces[name].controls['press'] = 0 if kind == 'axel_pong'
    @clients[name].attach_view(Form.new([]), @surfaces[name])
  end

  def advance_native(count = 1)
    count.times do
      @now += 0.016
      @clients.each_value { |client| client.progress_frame(background: false) }
    end
  end

  def complete_point(kind)
    advance_native(40)
    projection = @wrappers.fetch('Host').projection
    server = projection.players[projection.first_server]
    unless GameRoomParticipants.bot?(server)
      if kind == 'axel_pong'
        @surfaces.fetch(server).controls['press'] += 1
      else
        @surfaces.fetch(server).push('prepare', 'up')
      end
    end
    1_000.times do
      advance_native
      receipt = @clients.fetch('Host').context_data['duck_realtime_point']
      return receipt if receipt
    end
    raise 'The native engines did not agree on one point through the Duck client'
  end
end

DuckClientNativeMatchesTest.new.run
