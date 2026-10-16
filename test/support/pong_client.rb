require_relative 'ui'
require_relative 'log'
class Program
  def self.server_app(**_options); end
  def communication; end
end
class FormTimer
  def initialize(*_args, **_kwargs); end
end unless defined?(FormTimer)
require_relative '../../__app'
require_relative '../../lib/axel_pong/client'

def assert(value, message); raise message unless value; end

# Remote spectators present authenticated full snapshots. Their local engine
# deliberately does not reconstruct a history of returns it never received.
def pong_remote_observer?(client)
  !client.host? && client.instance_variable_get(:@side).nil?
end

def pong_presented_turn(client)
  pong_remote_observer?(client) ? client.instance_variable_get(:@observer_turn) : client.engine.turn
end

def pong_presented_goal(client)
  pong_remote_observer?(client) ? client.snapshot.fetch('goal') : client.engine.goal
end
class PongTestAudio
  attr_reader :updates
  def initialize; @updates = []; end
  def load; end
  def reset; end
  def silence; end
  def suspend; end
  def tick; end
  def point(_scores, viewer:, **_options); end
  def goal(viewer:, winner:); end
  def start_match; end
  def close; end
  def update(s, viewer:, paused:); @updates << [s, viewer, paused]; end
  def feedback(s, viewer:, paused:); end
end
class PongTestChannel
  attr_accessor :epoch, :connected, :drop, :hold_events
  attr_reader :match, :viewer, :inbox, :sent, :resets, :event_inbox, :event_sent, :p2p_options
  def initialize(network, **args)
    @network, @match, @viewer = network, args[:match], args[:viewer].downcase
    @inbox, @sent, @event_inbox, @event_sent, @held = {}, [], [], [], []
    @owner = args[:owner].downcase
    @epoch, @connected, @resets = 'generation1', true, 0
    network[@viewer] = self
  end
  def enable_events(mode = 'pong-local-1', routing: :owner); @events, @routing = mode, routing; end
  def configure_p2p(options); @p2p_options = GameRoomRealtime::P2POptions.session_options(options); end
  def event_protocol; @events; end
  def tick; end
  def take_events; result, @event_inbox = @event_inbox, []; result; end
  def connected?; @connected; end
  def take_packets; result, @inbox = @inbox, {}; result; end
  def send(data)
    return false unless connected?
    @sent << data
    return true if @drop
    packet = JSON.parse(data)
    @network.each do |name, channel|
      next if name == @viewer || channel.epoch != packet['e']
      next if @viewer != @owner && name != @owner
      channel.inbox[@viewer] = packet
    end
    true
  end
  def send_event(data)
    return false unless connected? && @events
    @event_sent << data
    @hold_events ? @held << data : deliver_event(data)
    true
  end
  def release_events
    @hold_events = false
    @held.each { |data| deliver_event(data) }
    @held.clear
  end
  def deliver_event(data)
    packet = JSON.parse(data)
    @network.each do |name, channel|
      next if name == @viewer || channel.epoch != packet['e']
      next if @routing != :peers && @viewer != @owner && name != @owner
      channel.event_inbox << [@viewer, packet]
    end
  end
  def reconnect(reason: nil); @resets += 1; end
  def close; @connected = false; end
end
class PongTestSurface
  attr_accessor :controls
  attr_reader :commits, :current, :status
  def initialize; @controls = {'move' => 0, 'hit' => false}; @commits = []; end
  def input(_form); @controls; end
  def present(s, status); @current, @status = s, status; end
  def commit_point(value); @commits << value; end
end

class PongHarness
  attr_reader :clients, :surfaces, :network, :replay, :players, :rules, :repository, :session, :programs
  attr_accessor :now
  def initialize(players: %w[Alice Bob], viewers: nil, options: {}, preferences: {}, session: nil, session_id: 300, table_id: 20, owner: 'Alice', initial_events: nil)
    @owner = owner
    @players = players
    @viewers = viewers || ([owner] + players + ['Watcher']).uniq
    @now, @network, @clients, @surfaces = 0.0, {}, {}, {}
    @programs = {}
    @rules = GameRoomGames::AxelPong.new
    @repository = Object.new
    def @repository.players_for(s); s['__players']; end
    def @repository.actor_of(e, _s); e['actor']; end
    def @repository.event_id(e); e['__id']; end
    @session = session || {'__players' => players, '__insertion_user' => owner, 'player_one' => owner,
      'options' => JSON.generate(@rules.default_options.merge(options))}
    @events = initial_events ? initial_events.dup : []
    @replay = @rules.replay(@session, @events, @repository)
    @viewers.each do |name|
      program = Program.new
      program.instance_variable_set(:@pong_preferences, GameRoomPong::Preferences.normalize(preferences[name]))
      program.define_singleton_method(:pong_preferences) { @pong_preferences }
      @programs[name] = program
      client = @rules.build_client(program, clock: -> { @now }, audio: PongTestAudio.new,
        channel_factory: ->(**args) { PongTestChannel.new(@network, **args) })
      client.bind_screen(session_id: session_id, table_id: table_id, owner: owner, viewer: name, members: -> { @viewers })
      client.start
      client.before_wait(@replay, name)
      @surfaces[name] = PongTestSurface.new
      @surfaces[name].controls['press'] = 0
      client.attach_view(Form.new([]), @surfaces[name])
      @clients[name] = client
    end
  end
  def advance(count, names: @viewers)
    count.times { @now += 0.016; names.each { |name| @clients[name].frame } }
  end
  def press(name, move: 0)
    @surfaces[name].controls['move'] = move
    @surfaces[name].controls['press'] += 1
  end
  def accept_point(value)
    @events << {'__id' => @events.length + 1, 'actor' => @owner, 'action' => 'pong_point', 'value' => value}
    @replay = @rules.replay(@session, @events, @repository)
    @clients.each { |name, client| client.before_wait(@replay, name) }
  end
  def close; @clients.each_value(&:close); end
end
