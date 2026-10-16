require_relative 'sequence_random'

require_relative 'pong_client'
require_relative '../../games/audio_ball'
require_relative '../../lib/audio_ball/client' if File.file?(File.expand_path('../../lib/audio_ball/client.rb', __dir__))

class AudioBallTestAudio
  attr_reader :calls
  def initialize; @calls = []; end
  def load; @calls << [:load]; end
  def reset; @calls << [:reset]; end
  def close; @calls << [:close]; end
  def update(snapshot, viewer:, paused:); @calls << [:update, snapshot, viewer, paused]; end
  def prepare(side, viewer:); @calls << [:prepare, side, viewer]; end
  def hurry(player); @calls << [:hurry, player]; end
  def announce_set(number); @calls << [:set, number]; end
  def point(scores, **options); @calls << [:point, scores, options]; end
  def goal(**options); @calls << [:goal, options]; end
end

class AudioBallTestChannel < PongTestChannel
  attr_accessor :required_members, :missing
  attr_reader :routing, :reasons
  def initialize(network, **args)
    super
    @missing, @reasons = [], []
  end
  def required_members_present?
    connected? && @required_members.to_a.all? do |name|
      name.casecmp?(@viewer) || (!@missing.include?(name.downcase) && @network[name.downcase]&.connected?)
    end
  end
  def reconnect(reason: nil)
    super
    @reasons << reason
  end
end

class AudioBallTestSurface
  attr_accessor :on_audio_ball_command
  attr_reader :current, :status, :reads
  def initialize; @commands, @reads = [], 0; end
  def push(*commands); @commands.concat(commands); end
  def input(_form)
    @reads += 1
    result, @commands = @commands, []
    result
  end
  def present(snapshot, status); @current, @status = snapshot, status; end
end

class AudioBallHarness
  attr_reader :clients, :surfaces, :network, :audios, :replay, :players, :game, :repository, :session, :events, :forms
  attr_accessor :now
  def initialize(players: %w[Alice Bob], owner: 'Alice', viewers: nil, options: {}, server: 0, connected: true, started: true, audio_factory: nil,
    session: nil, session_id: 300, table_id: 20, initial_events: nil)
    @session_id, @table_id = session_id, table_id
    @owner, @players = owner, players
    @audio_factory = audio_factory
    @viewers = viewers || ([owner] + players.reject { |player| GameRoomParticipants.bot?(player) } + ['Watcher']).uniq
    @now, @network, @clients, @surfaces, @audios, @forms = 0.0, {}, {}, {}, {}, {}
    @game = GameRoomGames::AudioBall.new
    @repository = Object.new
    def @repository.players_for(session); session['__players']; end
    def @repository.actor_of(event, _session); event['actor']; end
    def @repository.event_id(event); event['__id']; end
    @session = session || {'__players' => players, '__insertion_user' => owner, 'player_one' => players.first,
      'options' => JSON.generate(@game.default_options.merge(options))}
    @events = initial_events || []
    @replay = @game.replay(@session, @events, @repository)
    if started
      context = GameRoomGames::ActionContext.new(table_owner: owner, random_source: GameRoomRandom::SequenceSource.new([server + 1]), local_data: {})
      selection = @game.automatic_action(@replay, owner, context: context)
      status, plan = @game.action_for(selection, @replay, owner, context: context)
      raise 'start was not accepted' unless status == :ok
      append(plan)
    end
    @viewers.each { |name| add_client(name, connected: connected) }
  end
  def points_to_win; GameRoomGames::AudioBall::POINTS_TO_WIN; end
  def add_client(name, connected: true)
    @audios[name] = @audio_factory ? @audio_factory.call(clock: -> { @now }) : AudioBallTestAudio.new
    client = @game.build_client(Program.new, clock: -> { @now }, audio: @audios[name],
      channel_factory: ->(**args) { AudioBallTestChannel.new(@network, **args) })
    client.bind_screen(session_id: @session_id, table_id: @table_id, owner: @owner, viewer: name, members: -> { @viewers })
    @network[name.downcase].connected = connected
    @network[name.downcase].epoch = nil unless connected
    client.start
    client.before_wait(@replay, name)
    @surfaces[name], @forms[name] = AudioBallTestSurface.new, Form.new([])
    client.attach_view(@forms[name], @surfaces[name])
    @clients[name] = client
    @viewers << name unless @viewers.include?(name)
    client
  end
  def advance(count = 1, seconds: 0.016, names: @viewers)
    count.times { @now += seconds; names.each { |name| @clients[name].frame } }
  end
  def press(name, *commands)
    @surfaces[name].push(*commands)
    advance
  end
  def advance_for(seconds)
    target = @now + seconds
    advance(seconds: [0.016, target - @now].min) while @now < target - 1e-9
  end
  def append(plan)
    plan.events.each do |event|
      @events << {'__id' => @events.length + 1, 'actor' => @owner, '__insertion_user' => @owner,
        'action' => event.action, 'value' => event.value, 'created_at' => 100 + @now.to_i}
    end
    @replay = @game.replay(@session, @events, @repository)
  end
  def commit
    before = @replay
    data = @clients.fetch(@owner).context_data
    context = GameRoomGames::ActionContext.new(table_owner: @owner, local_data: data, now: 100 + @now)
    selection = @game.automatic_action(@replay, @owner, context: context)
    raise 'no agreed point' unless selection
    status, plan = @game.action_for(selection, @replay, @owner, context: context)
    raise 'agreed point rejected' unless status == :ok
    append(plan)
    @clients.each do |name, client|
      client.before_wait(@replay, name)
      client.event(@events.last, before, @replay, name, @repository)
    end
  end
  def win_point(name, persist: true)
    side = @players.index(name)
    server = @players[@replay.state[:server]]
    press(@players[1 - side], 'left')
    press(server, 'prepare', 'up')
    if server != name
      200.times do
        advance
        engine = @clients[name].engine
        endpoint = side == 0 ? 25.0 : 0.0
        break if engine.phase == :flying && (engine.position - endpoint).abs < 1.4
      end
      press(name, 'up')
      raise 'scripted human missed its legal defense' unless @clients[name].engine.holder == side
      press(name, 'prepare', 'down')
    end
    200.times do
      advance
      break if @clients[@owner].context_data['audio_ball_point']
    end
    raise 'human point did not reach agreement' unless @clients[@owner].context_data['audio_ball_point'] == "#{@replay.state[:rally]}:#{side}"
    commit if persist
  end
  def inject(target, sender, body, epoch: nil, match: nil, sequence: 1)
    channel = @network.fetch(target.downcase)
    data = GameRoomRealtime::Protocol.encode(match: match || channel.match, epoch: epoch || channel.epoch,
      sequence: sequence, kind: 'event', body: {'r' => @replay.state[:rally]}.merge(body))
    channel.event_inbox << [sender.downcase, JSON.parse(data)]
  end
  def close; @clients.each_value(&:close); end
end
