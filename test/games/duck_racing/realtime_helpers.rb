require_relative '../../support/audio_ball_client'
require_relative '../../support/assertions'
require_relative '../../../lib/duck_racing/realtime_client'

class DuckPongTestAudio < PongTestAudio
  attr_reader :calls
  def initialize(clock:)
    super()
    @clock, @calls = clock, []
  end
  def goal(**options)
    @calls << [:goal, options]
    @until = @clock.call + 0.18
  end
  def start_match; @calls << [:start]; end
  def close; @calls << [:close]; end
  def announcement_pending?; @until && @clock.call < @until; end
end

class DuckBallTestAudio < AudioBallTestAudio
  def initialize(clock:)
    super()
    @clock = clock
  end
  def goal(**options)
    super
    @until = @clock.call + 0.18
  end
  def announce(text); @calls << [:announce, text]; end
  def tick; end
  def announcement_pending?; @until && @clock.call < @until; end
end

class DuckRealtimeHarness
  attr_reader :wrappers, :surfaces, :audios, :network, :parent, :programs, :activity,
    :session, :created, :forms, :viewers
  attr_accessor :now

  def initialize(kind:, racers: %w[Host Alice Bob Watcher], pair: [1, 2], seed: 90,
    owner: 'Host', id: 1)
    @now, @network, @wrappers, @surfaces, @audios, @programs = 0.0, {}, {}, {}, {}, {}
    @created, @activity, @forms, @owner = [], [], {}, owner
    @viewers = (racers.reject { |name| GameRoomParticipants.bot?(name) } + [owner]).uniq
    @parent = GameRoomGames::Replay.new(players: racers, current_player: nil, draw: false,
      winner: nil, accepted_events: [], history: [], state: {
        options: {'difficulty' => 5, 'arcade' => true},
        race: {phase: :challenge, challenge: {id: id, kind: kind, participants: pair, seed: seed}}
      })
    @session = {'__players' => racers.dup, '__initial_players' => racers.dup,
      '__control_epoch' => 'initial', '__table_owner' => owner,
      '__controllers' => racers.to_h { |name| [name, GameRoomParticipants.bot?(name) ? 'bot' : name] }}
    transport = Object.new
    activities = @activity
    transport.define_singleton_method(:note_realtime_activity) { |table, session| activities << [table, session] }
    @viewers.each do |name|
      program = @programs[name] = Program.new
      program.instance_variable_set(:@pong_preferences, GameRoomPong::Preferences.normalize('auto_return' => false))
      program.define_singleton_method(:pong_preferences) { @pong_preferences }
      factory = lambda do |native_kind, game, **options|
        audio_type = native_kind == 'axel_pong' ? DuckPongTestAudio : DuckBallTestAudio
        @audios[name] = audio_type.new(clock: -> { @now })
        type = native_kind == 'axel_pong' ? GameRoomPong::Client : GameRoomAudioBall::Client
        client = type.new(program, game, **options, audio: @audios[name],
          channel_factory: ->(**args) { AudioBallTestChannel.new(@network, **args) })
        @created << client
        client
      end
      client = GameRoomDuckRacing::RealtimeClient.new(program, clock: -> { @now }, transport: transport,
        client_factory: factory)
      @wrappers[name] = client
      client.bind_screen(session_id: 300, table_id: 20, owner: owner, viewer: name, members: -> { @viewers })
      client.start
      client.update_table_control(@session)
      client.before_wait(@parent, name)
      attach(name, kind)
    end
  end

  def attach(name, kind = @parent.state[:race][:challenge][:kind])
    @surfaces[name] = kind == 'axel_pong' ? PongTestSurface.new : AudioBallTestSurface.new
    @surfaces[name].controls['press'] = 0 if kind == 'axel_pong'
    @forms[name] = Form.new([])
    @wrappers[name].attach_view(@forms[name], @surfaces[name])
  end

  def advance(count = 1, seconds: 0.016)
    count.times do
      @now += seconds
      @wrappers.each_value(&:frame)
    end
  end

  def complete_native_point
    advance(40)
    server = @wrappers.values.first.projection.first_server
    names = @wrappers.values.first.projection.players
    name = names[server]
    unless GameRoomParticipants.bot?(name)
      surface = @surfaces.fetch(name)
      if surface.is_a?(PongTestSurface)
        surface.controls['press'] += 1
      else
        surface.push('prepare', 'up')
      end
    end
    500.times do
      advance
      receipt = @wrappers.fetch(@owner).context_data['duck_realtime_point']
      return receipt if receipt
    end
    raise 'Native single point did not agree'
  end

  def owner=(name)
    @owner = name
  end

  def close
    @wrappers.each_value(&:close)
  end
end
