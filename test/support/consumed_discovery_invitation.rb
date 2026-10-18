require_relative 'native_tasks'
require_relative 'native_live_endpoint'
require_relative 'assertions'
require_relative '../../lib/live_session_store'
require_relative '../../lib/invitation_repository'
Object.include(GameRoomTest::Assertions)

module ServerClock
  def self.now; Time.now; end
end unless defined?(ServerClock)

# The SDK invitation, discovery, Session, queue and callback implementations
# are real. Only server responses and the unrelated room-stack projection
# are supplied locally; every unexpected HTTP boundary raises.
class ConsumedDiscoveryInvitationFixture
  attr_reader :endpoint, :program, :store, :calls
  attr_accessor :join_error, :after_admission, :context_override

  def initialize
    @calls = []
    @endpoint = build_endpoint('Bob')
    @program = Struct.new(:live_sessions).new(@endpoint)
    @store = GameRoomLiveSessionStore.new(@program)
    fixture = self
    @store.define_singleton_method(:ensure_current) { |*_args, **_options| nil }
    @store.define_singleton_method(:room_snapshot) do |id, **_options|
      native = active_session(id)
      fixture.after_admission&.call
      {table: fixture.table(id), members: native.participants.map(&:user), bots: [], observers: []}
    end
    @store.send(:endpoint)
  end

  def build_endpoint(user)
    item = EltenAPI::LiveSessions::Endpoint.new(app_id: 'ef8a0700-2d36-411b-ae13-6e6811a63a78',
      client: NativeLiveEndpointFixture::Client.new(Object.new), user: user, token: 'offline-fixture')
    (@endpoints ||= []) << item
    fixture = self
    item.define_singleton_method(:discover_sessions) do |**_options|
      EltenAPI::LiveSessions::DiscoveryPage.new(self, {'items' => [41, 42].map { |id| fixture.discovery(id) }})
    end
    item.define_singleton_method(:discovery_request) do |operation, parameters, **options|
      fixture.calls << [operation, parameters, options]
      raise fixture.join_error if fixture.join_error
      raise 'Unexpected HTTP boundary' unless [:join, :accept, :reject].include?(operation)
      next {} if operation == :reject
      id = options.fetch(:session_id).split('-').last.to_i
      fixture.snapshot(id, user)
    end
    item
  end

  def metadata(id)
    {'kind' => GameRoomLiveSessionStore::KIND, 'protocol' => GameRoomLiveSessionStore::PROTOCOL,
      'table_id' => id, 'game' => 'tic_tac_toe'}
  end

  def table(id = 41)
    {'__id' => id, '__live_session_id' => "native-room-#{id}", 'status' => 'waiting', 'max_players' => 8}
  end

  def packet(id = 41, generation = 1, app_id: 91, user: 'Alice')
    {'session_id' => "native-room-#{id}", 'invitation_id' => "server-#{id}-#{generation}", 'generation' => generation,
      'metadata' => metadata(id), 'invitation_metadata' => {'purpose' => 'game_invitation', 'invitation_id' => app_id, 'sender' => user},
      'invited_by' => {'id' => "participant-#{user}", 'user' => user}, 'expires_at' => Time.now.to_i + 300}
  end

  def discovery(id)
    {'id' => "native-room-#{id}", 'state' => 'open', 'discovery_token' => 'offline-token',
      'discovery_metadata' => metadata(id), 'can_join' => true, 'limits' => {}}
  end

  def snapshot(id, user)
    context = @context_override || {'method' => 'invitation', 'invitation_id' => "server-#{id}-1", 'invitation_generation' => 1}
    {'id' => "native-room-#{id}", 'metadata' => metadata(id), 'participant_id' => "participant-#{user}",
      'owner_id' => 'participant-Alice', 'participants' => [
        {'id' => 'participant-Alice', 'user' => 'Alice'}, {'id' => "participant-#{user}", 'user' => user}],
      'join_context' => context, 'limits' => {'stack' => true}}
  end

  def deliver(id = 41, generation = 1, app_id: 91, endpoint: @endpoint)
    endpoint.send(:receive_invitation, packet(id, generation, app_id: app_id))
    endpoint.dispatch_events
    @store.pending_invitations.find { |row| row['__id'] == app_id && row['table_id'] == id }
  end

  def repo
    InvitationRepository.new(transport: @store, current_user: -> { @program.live_sessions.user })
  end

  def join
    @store.join_room(table, 'Bob')
  end

  def close
    @endpoints.each do |item|
      item.close
      EltenAPI::LiveSessions.unregister(item)
    end
  end
end

def with_consumed_invitation
  fixture = ConsumedDiscoveryInvitationFixture.new
  yield fixture
ensure
  fixture&.close
end
