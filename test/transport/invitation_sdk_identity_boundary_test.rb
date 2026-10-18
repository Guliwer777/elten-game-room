require_relative '../support/native_tasks'
require_relative '../support/assertions'
require_relative '../support/native_live_endpoint'
require_relative '../../lib/live_session_store'
Object.include(GameRoomTest::Assertions)

module ServerClock
  def self.now; Time.now; end
end unless defined?(ServerClock)

client = NativeLiveEndpointFixture::Client.new(Object.new)
endpoint = EltenAPI::LiveSessions::Endpoint.new(app_id: 'ef8a0700-2d36-411b-ae13-6e6811a63a78',
  client: client, user: 'Bob', token: 'offline-fixture')
program = Struct.new(:live_sessions).new(endpoint)
store = GameRoomLiveSessionStore.new(program)
calls = []
endpoint.define_singleton_method(:discovery_request) do |operation, parameters, **options|
  raise 'Unexpected offline SDK request' unless operation == :reject
  calls << [operation, parameters, options]
  {}
end
packet = lambda do |uuid, table, sender, generation|
  {'session_id' => uuid, 'invitation_id' => "server-#{uuid}-#{generation}", 'generation' => generation,
   'metadata' => {'kind' => GameRoomLiveSessionStore::KIND, 'protocol' => GameRoomLiveSessionStore::PROTOCOL,
     'table_id' => table, 'game' => 'uno'},
   'invitation_metadata' => {'purpose' => 'game_invitation', 'invitation_id' => 91, 'sender' => sender},
   'invited_by' => {'id' => "participant-#{sender}", 'user' => sender}, 'expires_at' => Time.now.to_i + 300}
end

begin
  store.send(:endpoint) # Register the production callback with the real SDK.
  endpoint.send(:receive_invitation, packet.call('native-a', 7, 'Alice', 1))
  endpoint.send(:receive_invitation, packet.call('native-b', 8, 'Carol', 1))
  endpoint.dispatch_events
  rows = store.pending_invitations
  assert(rows.map { |row| row['table_id'] }.sort == [7, 8], 'SDK callback/queue lost a colliding app ID')
  previous = rows.find { |row| row['table_id'] == 8 }.fetch('__native_invitation')
  assert(store.reject_invitation(table_id: 7, invitation_id: 91), 'Exact SDK invitation rejection failed')
  assert(calls == [[:reject, {'invitation_id' => 'server-native-a-1'}, {session_id: 'native-a'}]],
    'Rejection used app ID, wrong native UUID, or another invitation authority')
  assert(store.pending_invitations.map { |row| row['sender'] } == ['Carol'], 'Resolving A consumed B')

  # Actual SDK supersession differs from a naive broker: one newer native
  # invitation replaces the old inviter for this session before callbacks run.
  endpoint.send(:receive_invitation, packet.call('native-b', 8, 'Dave', 2))
  endpoint.dispatch_events
  assert(previous.superseded? && !previous.pending?, 'Real SDK did not establish the supersession boundary')
  store.send(:receive_invitation, previous, source: endpoint)
  endpoint.send(:receive_invitation, packet.call('native-b', 8, 'Carol', 1))
  endpoint.dispatch_events
  rows = store.pending_invitations
  assert(rows.size == 1 && rows.first['sender'] == 'Dave', 'Old queued/callback invitation defeated SDK supersession')

  # Distinct native rooms sharing an app table number must fail closed when
  # an old entry point supplies only the table number and app invitation ID.
  endpoint.send(:receive_invitation, packet.call('native-c', 8, 'Eve', 1))
  endpoint.dispatch_events
  before = calls.dup
  assert(!store.reject_invitation(table_id: 8, invitation_id: 91), 'An ambiguous legacy scope selected a native room')
  assert(calls == before && store.pending_invitations.size == 2, 'Ambiguous rejection performed I/O or consumed choices')
  assert(store.pending_invitations.map { |row| row['recipient'] }.uniq == ['Bob'], 'SDK recipient authority lost')
ensure
  endpoint.close
  EltenAPI::LiveSessions.unregister(endpoint)
end
puts 'PASS actual SDK invitation callback/queue, collision, supersession, exact native rejection and ambiguous legacy denial (offline)'
