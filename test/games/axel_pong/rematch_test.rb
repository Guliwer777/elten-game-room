require_relative "../../support/relay"

module Session
  def self.name; @name || 'Alice'; end
  def self.name=(value); @name = value; end
end

class RematchAudio < PongTestAudio
  attr_reader :closed, :points, :loads
  def initialize; super; @points, @loads = [], 0; end
  def load; @loads += 1; end
  def close; @closed = true; end
  def point(scores, **options); @points << [scores.dup, options]; end
end

class RematchRepository
  attr_accessor :available
  attr_reader :sessions, :table_reads
  def initialize; @sessions, @available, @table_reads = {}, true, []; end
  def session_id(session); session['__id']; end
  def players_for(session); session['__players']; end
  def actor_of(event, _session); event['actor']; end
  def event_id(event); event['__id']; end
  def session_by_id(id, table:); @sessions[id] if @available && table['__id'] == 20; end
  def session_for_table(table, force: false)
    @table_reads << [table['__id'], force]
    @sessions.values.reverse.find { |session| session['table_id'] == table['__id'] } if @available
  end
end

class RematchSync
  attr_reader :session_id, :recovery
  def update_session(id, **_options); @session_id = id; self; end
  def synchronized!; self; end
  def next_reconcile_at; Float::INFINITY; end
  def request_recovery!(**_options); @recovery = true; end
end

# Real GameScreen session switching, Pong replay/clients and both Communications
# lanes. Only public network endpoints, clocks, audio and the repository read
# are deterministic fixtures; no live accounts or installed app are touched.
class RematchHarness
  attr_reader :rules, :repository, :screens, :rig, :replay, :session, :forms, :surfaces, :built
  def initialize
    @rig, @rules, @repository = RelayFixture.new, GameRoomGames::AxelPong.new, RematchRepository.new
    @viewers = %w[Alice Bob Watcher]
    @screens, @forms, @surfaces, @built = {}, {}, {}, []
    factory = self
    @rules.define_singleton_method(:build_client) { |program, **_services| factory.build_client(program) }
    new_session(300, target: 7)
    @viewers.each do |name|
      program = Program.new
      program.define_singleton_method(:rematch_viewer) { name }
      rig = @rig
      program.define_singleton_method(:communication) { rig.endpoint(name) }
      program.define_singleton_method(:release) { |_resource| }
      screen = GameScreen.allocate
      controller = Object.new
      controller.define_singleton_method(:switch_session) { |_id| }
      {game: @rules, program: program, game_services: {}, repository: @repository,
        session: @session, table: {'__id' => 20}, table_owner: 'Alice',
        synchronizer: RematchSync.new, bot_turn_controller: controller}.each do |key, value|
        screen.instance_variable_set("@#{key}", value)
      end
      screen.define_singleton_method(:synchronized_network_task) { |_title, **_options, &operation| operation.call }
      screen.define_singleton_method(:game_recipients) { %w[Alice Bob Watcher] }
      client = build_client(program)
      client.bind_screen(session_id: 300, table_id: 20, owner: 'Alice', viewer: name,
        members: -> { %w[Alice Bob Watcher] })
      client.start
      screen.instance_variable_set(:@game_client, client)
      @screens[name] = screen
      attach(name)
    end
  end

  def build_client(program)
    name = program.rematch_viewer
    client = GameRoomPong::Client.new(program, @rules, clock: -> { @rig.now }, audio: RematchAudio.new,
      channel_factory: ->(**args) { GameRoomRealtime::EventChannel.new(**args,
        work_factory: -> { @rig.worker(name) }, event_work_factory: -> { @rig.worker(name) }) })
    @built << client
    client
  end

  def new_session(id, target:, players: %w[Alice Bob])
    @session = {'__id' => id, 'table_id' => 20, '__players' => players,
      '__insertion_user' => 'Alice', 'player_one' => players.first,
      'options' => JSON.generate(@rules.default_options.merge('target' => target))}
    @repository.sessions[id] = @session
    @events = []
    @replay = @rules.replay(@session, @events, @repository)
  end

  def clients; @screens.transform_values { |screen| screen.instance_variable_get(:@game_client) }; end
  def channel(client); client.instance_variable_get(:@channel); end
  def audio(client); client.instance_variable_get(:@audio); end

  def attach(name)
    client = clients.fetch(name)
    client.before_wait(@replay, name)
    @forms[name], @surfaces[name] = Form.new([]), PongTestSurface.new
    @surfaces[name].controls['press'] = 0
    client.attach_view(@forms[name], @surfaces[name])
  end

  def advance(count)
    count.times do
      @rig.now += 0.016
      @rig.advance_work
      clients.each_value(&:frame)
    end
  end

  def point(side)
    before = @replay
    event = {'__id' => @events.length + 1, 'actor' => 'Alice', 'action' => 'pong_point',
      'value' => "#{@events.length}:#{side}"}
    @events << event
    @replay = @rules.replay(@session, @events, @repository)
    clients.each do |name, client|
      client.before_wait(@replay, name)
      client.event(event, before, @replay, name, @repository)
    end
  end

  def switch(name, id = @session['__id'])
    Session.name = name
    screen = @screens.fetch(name)
    screen.instance_variable_set(:@new_session_id, id)
    screen.send(:switch_to_new_session)
  ensure
    Session.name = 'Alice'
  end

  def close; @built.each(&:close); @rig.advance_work; end
end

h = RematchHarness.new
begin
  h.advance(300)
  assert(h.clients.values.none?(&:paused), 'first match never became ready')
  3.times { h.point(1) }
  7.times { h.point(0) }
  assert(h.replay.finished? && h.replay.state[:scores] == [7, 3], 'fixture did not finish a real 7-point match')
  previous = h.clients
  previous_forms = h.forms.dup
  previous.each_value do |client|
    assert(client.send(:presentation_state).announced_rally == 10, 'old announcements not exercised')
    assert(h.channel(client).instance_variable_get(:@closed), 'finished match did not close its channel')
    assert(h.channel(client).instance_variable_get(:@work).instance_variable_get(:@closed), 'old operation lane not closed')
    assert(h.channel(client).instance_variable_get(:@event_work).instance_variable_get(:@closed), 'old event lane not closed')
  end
  puts 'PRECONDITION: 7:3 finished, rally/announcement=10, channel and both operation lanes closed'

  # Exact reported case: same room, target changes 7 -> 21, new LiveSession.
  h.new_session(301, target: 21)
  h.screens.each_key { |name| h.switch(name) }
  h.clients.each do |name, client|
    assert(!client.equal?(previous[name]), "#{name}: rematch reused the old client with its closed channel")
    assert(previous[name].instance_variable_get(:@closed) && h.audio(previous[name]).closed, 'old client/audio not released')
    assert(previous_forms[name].instance_variable_get(:@timers).empty?, 'old view timer survived the rematch')
    expected = Digest::SHA256.hexdigest('GameRoom:axel_pong:20:301')[0, 24]
    assert(client.instance_variable_get(:@match) == expected, 'new client bound to the wrong match')
    assert(!h.channel(client).instance_variable_get(:@closed), 'new channel already closed')
    assert(client.send(:presentation_state).announced_rally.nil?, 'old announcement counter survived')
    assert(h.audio(client).loads == 1, 'new client was not started exactly once')
    h.attach(name)
  end
  h.advance(300)
  assert(h.clients.values.none?(&:paused), '7 -> 21 rematch stuck during handshake')
  h.surfaces['Alice'].controls['press'] = 1
  h.advance(3)
  assert(h.clients['Alice'].engine.ball['dy'] != 0 && h.clients['Bob'].engine.ball['dy'] != 0, 'second match cannot serve')
  current = h.clients
  engines = current.transform_values(&:engine)
  h.screens.each_key { |name| h.switch(name) }
  h.clients.each do |name, client|
    assert(client.equal?(current[name]) && client.engine.equal?(engines[name]), 'duplicate session notification restarted the rally')
    client.before_wait(h.replay, name)
    assert(client.engine.equal?(engines[name]), 'ordinary refresh restarted the rally')
  end
  # A native notification can name a rejected start. The fresh authoritative
  # table lookup then still returns this game, without recreating its client.
  h.screens.each do |name, screen|
    assert(h.switch(name, 999_999) == true, 'rejected start did not retain the authoritative current game')
    assert(screen.instance_variable_get(:@new_session_id).nil?, 'rejected start remained pending')
    assert(h.clients[name].equal?(current[name]) && h.clients[name].engine.equal?(engines[name]), 'rejected start reset the current client')
  end
  assert(h.repository.table_reads.select(&:last) == Array.new(3) { [20, true] }, 'missing IDs did not force the correct table projection')
  assert(h.repository.table_reads.reject(&:last) == Array.new(9) { [20, false] }, 'session switches did not check the cached latest game exactly once')
  # Late callbacks/invitations from the old match must not replace the new one.
  endpoints = h.rig.endpoints.dup
  old_group = h.rig.groups.first
  h.rig.endpoints['Bob'].enqueue(RelayInvite.new(h.rig.endpoints['Bob'], old_group))
  previous.each_value { |client| client.frame; client.close }
  h.advance(5)
  assert(endpoints == h.rig.endpoints && endpoints.values.none?(&:closed?), 'late old work damaged the new endpoints')
  h.point(1)
  h.clients.each_value { |client| assert(h.audio(client).points.map(&:first) == [[0, 1]], 'new first point announcement suppressed') }
  h.advance(400)
  assert(h.clients.values.none?(&:paused), 'next rally of second match did not resume')
  7.times { h.point(0) }
  assert(!h.replay.finished?, 'second match kept the old 7-point target')
  14.times { h.point(0) }
  assert(h.replay.finished? && h.replay.state[:scores] == [21, 1], 'second match did not finish at 21')
  puts 'PASS rematch: real 7 -> 21 replay, host/guest/observer, fresh channels, serve and point announcements'

  # A failed read must retain the pending target and all current resources.
  # The next game keeps target=21 but changes human/bot roles. It still needs
  # a new client/channel/roster, despite using the same peer engine path.
  before_retry = h.clients
  h.new_session(302, target: 21, players: ['Bob', 'bot:20:1'])
  h.repository.available = false
  h.screens.each do |name, screen|
    assert(h.switch(name) != false, 'unavailable session was treated as fatal startup failure')
    assert(screen.instance_variable_get(:@new_session_id) == 302, 'failed read lost its target')
    assert(screen.instance_variable_get(:@synchronizer).recovery, 'failed read did not schedule recovery')
    assert(h.clients[name].equal?(before_retry[name]) && !h.audio(before_retry[name]).closed, 'failed read disposed the old client')
  end
  assert(h.repository.table_reads.select(&:last) == Array.new(6) { [20, true] }, 'failed read skipped its fresh lookup or queried another table')
  assert(h.repository.table_reads.reject(&:last) == Array.new(12) { [20, false] }, 'failed switch skipped or repeated its cached latest lookup')
  h.repository.available = true
  h.screens.each_key { |name| h.switch(name); h.attach(name) }
  h.advance(500)
  assert(h.clients.values.all? { |client| client.is_a?(GameRoomPong::PeerPlay) }, 'bot rematch reverted to owner-side input')
  assert(h.clients['Alice'].instance_variable_get(:@bots).length == 1 && h.clients['Bob'].instance_variable_get(:@bots).empty?,
    'rematch assigned the bot to the wrong controller')
  assert(h.clients.values.none?(&:paused), 'bot rematch with observing host never became ready')
  assert(h.clients.values.all? { |client| client.instance_variable_get(:@players) == ['Bob', 'bot:20:1'] }, 'old roster survived')
  21.times { h.point(0) }
  assert(h.replay.finished?, 'third match did not finish')
  h.new_session(303, target: 21)
  h.screens.each_key { |name| h.switch(name); h.attach(name) }
  h.advance(300)
  assert(h.clients.values.all? { |client| client.is_a?(GameRoomPong::PeerPlay) && !client.paused }, 'return from bot match to humans failed')
  assert(h.built.length == 12, 'client rebuilt during failed read, refresh or ordinary point')
  puts 'PASS rematch lifecycle: duplicate notification, late invitation, failed read/retry, unchanged settings and human/bot transitions'
ensure
  h.close
end

# A setup call can complete only after its entire old match has ended. Exercise
# the real generation/close guards, rather than letting it reopen the old lane.
h = RematchHarness.new
begin
  old = h.clients
  7.times { h.point(0) }
  h.new_session(304, target: 21)
  h.screens.each_key { |name| h.switch(name); h.attach(name) }
  h.advance(400)
  assert(h.clients.values.none?(&:paused), 'late endpoint setup prevented the rematch')
  old.each_value do |client|
    assert(h.channel(client).instance_variable_get(:@endpoint).nil?, 'late setup reopened the old channel')
  end
  assert(h.rig.endpoints.values.none?(&:closed?), 'stale setup closed replacement endpoints')
  puts 'PASS rematch with old endpoint setup still in flight'
ensure
  h.close
end
