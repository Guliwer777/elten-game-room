require_relative '../support/consumed_discovery_invitation'
require_relative '../../lib/lobby_repository'

# Real native Endpoint/Session, store and ordinary lobby. Only HTTP replies
# are supplied locally, including a controlled reentry at the old leave RPC.
class DeactivateMembershipFixture < ConsumedDiscoveryInvitationFixture
  def initialize
    super
    @store.singleton_class.send(:remove_method, :ensure_current)
    @store.singleton_class.send(:remove_method, :room_snapshot)
  end

  def metadata(id)
    super.merge('owner' => 'Alice', 'name' => "Room #{id}", 'created_at' => id,
      'game_options' => '{}', 'max_players' => 8)
  end

  def snapshot(id, user)
    result = super
    result['participants'].uniq! { |participant| participant['id'] }
    result
  end

  def build_endpoint(user)
    native = super
    fixture = self
    native.define_singleton_method(:stack_request) do |session, operation, params, **options|
      fixture.calls << [:stack, operation, session.id, params, options]
      raise 'Unexpected stack mutation' unless operation == :read
      {'session_id' => session.id, 'entries' => [], 'cursor' => 0, 'has_more' => false,
        'through' => 0, 'state' => {'last_seq' => 0, 'revision' => 0}}
    end
    [:leave_session, :close_session].each do |operation|
      native.define_singleton_method(operation) do |session|
        fixture.calls << [operation, session.id, session.participant_id]
        true
      end
    end
    native
  end

  def lobby
    transport = GameRoomTransport.new(program)
    transport.instance_variable_set(:@live_store, store)
    LobbyRepository.new(program, transport: transport)
  end

  def mark_current_queues
    room = store.instance_variable_get(:@rooms).fetch(41)
    room.pending_move = Object.new
    room.recovered_moves << Object.new
    room.private_game_messages << Object.new
    room.public_game_previews << Object.new
    [room, room.attachment, room.pending_move, room.recovered_moves.dup,
      room.private_game_messages.dup, room.public_game_previews.dup]
  end
end

failures = []
checks = 0
# The callback may be queued until the RPC caller returns, or dispatched
# before returning from native Session#leave. Both are ordinary SDK paths.
[false, true].each do |callback_first|
  [nil, 'Bob', 'Other'].each do |replacement_user|
    fixture = DeactivateMembershipFixture.new
    begin
      lobby = fixture.lobby
      initial = lobby.join_table(fixture.table, 'Bob', announce: false)
      assert(initial.status == :joined, 'Initial ordinary join failed')
      old_session = fixture.endpoint.sessions.fetch(0)
      old_queues = fixture.mark_current_queues
      replacement, new_session, new_queues = nil, nil, nil
      if replacement_user
        replacement = fixture.build_endpoint(replacement_user)
      end
      replace = lambda do
        next unless replacement
        fixture.program.live_sessions = replacement
        result = lobby.join_table(fixture.table, replacement_user, announce: false)
        assert(result.status == :joined, 'Replacement ordinary join failed')
        new_session = replacement.sessions.fetch(0)
        new_queues = fixture.mark_current_queues
      end
      if callback_first
        native_leave = old_session.method(:leave)
        old_session.define_singleton_method(:leave) do
          result = native_leave.call
          fixture.endpoint.dispatch_events
          assert(!fixture.store.active_membership?(41), 'Old close callback was not dispatched')
          replace.call
          result
        end
      else
        native_leave = fixture.endpoint.method(:leave_session)
        fixture.endpoint.define_singleton_method(:leave_session) do |session|
          result = native_leave.call(session)
          replace.call
          result
        end
      end
      result = lobby.leave_table(initial.table, 'Bob')
      fixture.endpoint.dispatch_events
      label = "callback_first=#{callback_first}, replacement=#{replacement_user.inspect}"
      failures << "#{label}: leave did not succeed" unless result && old_session.closed?
      if replacement
        room, token, pending, recovered, private_messages, previews = new_queues
        failures << "#{label}: current native attachment lost" unless fixture.store.send(:active_session, 41).equal?(new_session)
        failures << "#{label}: actual new session closed" unless !new_session.closed? && replacement.sessions.include?(new_session)
        failures << "#{label}: attachment token changed" unless fixture.store.membership_token(41).equal?(token)
        failures << "#{label}: pending move lost" unless room.pending_move.equal?(pending)
        failures << "#{label}: recovered moves lost" unless room.recovered_moves == recovered
        failures << "#{label}: private messages lost" unless room.private_game_messages == private_messages
        failures << "#{label}: public previews lost" unless room.public_game_previews == previews
        failures << "#{label}: native ID lost" unless fixture.store.instance_variable_get(:@native_session_ids)[new_session.id] == 41
        failures << "#{label}: new active visit retained as inactive" if fixture.store.instance_variable_get(:@inactive_rooms).key?(41)
      else
        room = old_queues[0]
        failures << "#{label}: old membership remains" if fixture.store.active_membership?(41)
        failures << "#{label}: old pending/recovery remains" if room.pending_move || !room.recovered_moves.empty?
        failures << "#{label}: old private messages/previews remain" unless room.private_game_messages.empty? && room.public_game_previews.empty?
        failures << "#{label}: old native ID remains" if fixture.store.instance_variable_get(:@native_session_ids).key?(old_session.id)
        failures << "#{label}: old visit not retained" unless fixture.store.instance_variable_get(:@inactive_rooms).key?(41)
      end
      checks += 1
    ensure
      fixture.close
    end
  end
end

# The owner closes the real native Session, rather than leaving a guest seat.
fixture = DeactivateMembershipFixture.new
begin
  owner = fixture.build_endpoint('Alice')
  fixture.program.live_sessions = owner
  lobby = fixture.lobby
  joined = lobby.join_table(fixture.table, 'Alice', announce: false)
  native = owner.sessions.fetch(0)
  assert(native.owner?, 'Owner control did not acquire native ownership')
  room = fixture.mark_current_queues[0]
  assert(lobby.leave_table(joined.table, 'Alice'), 'Owner close did not succeed')
  owner.dispatch_events
  assert(native.closed? && !fixture.store.active_membership?(41), 'Owner close left current membership')
  assert(fixture.calls.count { |entry| entry[0] == :close_session } == 1, 'Owner close was not sent exactly once')
  assert(fixture.calls.none? { |entry| entry[0] == :leave_session }, 'Owner used guest leave')
  assert(room.pending_move.nil? && room.recovered_moves.empty? && room.private_game_messages.empty? && room.public_game_previews.empty?,
    'Owner close did not clear its own queues')
ensure
  fixture.close
end
assert(failures.empty?, failures.join("\n"))
puts "PASS native deactivate boundary: #{checks} guest interleavings, full queue/cache identity, callback-first and actual owner close"
