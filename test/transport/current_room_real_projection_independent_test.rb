require_relative '../support/consumed_discovery_invitation'
require_relative '../../lib/lobby_repository'

# Use the actual SDK endpoint, Session, participants and discovery together
# with the unmodified current-room, room-stack and lobby projections. Only
# server responses are local; no account, profile or network is used here.
class CurrentRoomRealProjectionFixture < ConsumedDiscoveryInvitationFixture
  def initialize
    super
    @store.singleton_class.send(:remove_method, :ensure_current)
    @store.singleton_class.send(:remove_method, :room_snapshot)
  end

  def metadata(id)
    super.merge('owner' => 'Alice', 'name' => "Room #{id}", 'created_at' => id,
      'game_options' => '{}', 'max_players' => 8)
  end

  def build_endpoint(user)
    item = super
    fixture = self
    item.define_singleton_method(:stack_request) do |session, operation, params, **options|
      fixture.calls << [:stack, operation, session.id, params, options]
      raise 'Unexpected stack write' unless operation == :read
      {'session_id' => session.id, 'entries' => [], 'cursor' => 0, 'has_more' => false,
        'through' => 0, 'state' => {'last_seq' => 0, 'revision' => 0}}
    end
    item
  end
end

def with_real_current_room
  fixture = CurrentRoomRealProjectionFixture.new
  transport = GameRoomTransport.new(fixture.program)
  transport.instance_variable_set(:@live_store, fixture.store)
  lobby = LobbyRepository.new(fixture.program, transport: transport)
  yield fixture, lobby
ensure
  fixture&.close
end

['Bob', 'Other'].product([[41, 41], [42, 41], [41, 42]]).each do |user, (prior_id, next_id)|
  with_real_current_room do |fixture, lobby|
    assert_equal(:joined, lobby.join_table(fixture.table(prior_id), 'Bob', announce: false).status)
    old_native = fixture.endpoint.sessions.fetch(0)
    old_token = fixture.store.membership_token(prior_id)
    assert_equal(prior_id, lobby.current_table_for('Bob').fetch('__id'))

    replacement = fixture.build_endpoint(user)
    fixture.program.live_sessions = replacement
    before = fixture.calls.length
    assert_equal(nil, lobby.current_table_for(user), 'Old endpoint supplied a current room through the real projection')
    assert_equal(before, fixture.calls.length, 'Inspecting absent current membership sent a request')
    assert(!old_native.closed?, 'Read-only inspection released the old accepted visit')

    joined = lobby.join_table(fixture.table(next_id), user, announce: false)
    assert_equal(:joined, joined.status, 'Normal lobby bypassed joining the new endpoint')
    assert_equal(next_id, joined.table.fetch('__id'))
    assert_equal("Room #{next_id}", joined.table.fetch('name'), 'Metadata was not projected through table_for')
    assert_equal(['Alice', user], joined.members)
    assert_equal('Alice', joined.table.fetch('owner'))
    assert_equal(2, joined.table.fetch('player_count'))
    assert_equal('waiting', joined.table.fetch('status'))
    new_native = replacement.sessions.fetch(0)
    assert(!new_native.equal?(old_native), 'New endpoint retained the previous native object')
    assert(!old_token.equal?(fixture.store.membership_token(next_id)), 'New visit reused the former membership token')

    before = fixture.calls.length
    current = lobby.current_table_for(user)
    assert_equal(next_id, current.fetch('__id'), 'A higher-ID old attachment won over the real current visit')
    assert_equal(nil, lobby.current_table_for(user == 'Bob' ? 'Other' : 'Bob'))
    assert_equal(:already_here, lobby.join_table(current, user, announce: false).status)
    assert_equal(before, fixture.calls.length, 'Warm current-room/reopen unnecessarily read or wrote the network')

    blocked = lobby.join_table(fixture.table(next_id == 41 ? 42 : 41), user, announce: false)
    assert_equal(:already_at_another_table, blocked.status, 'An actual current visit no longer protects the one-table boundary')
    assert_equal(before, fixture.calls.length, 'The one-table guard joined a second table')
    assert(!old_native.closed?, 'New endpoint changed the old endpoint lifecycle')
  end
end

# Inject changes only after the real projection has been computed. Thus the
# final guard, rather than a stubbed empty projection, must reject the result.
[:account, :endpoint, :closure, :read_error].each do |change|
  with_real_current_room do |fixture, lobby|
    assert_equal(:joined, lobby.join_table(fixture.table, 'Bob', announce: false).status)
    native = fixture.endpoint.sessions.fetch(0)
    original = fixture.store.method(:project_room_records)
    calls = fixture.calls.length
    reached = false
    replacement = fixture.build_endpoint(change == :account ? 'Other' : 'Bob')
    fixture.store.define_singleton_method(:project_room_records) do |*args, **options|
      value = original.call(*args, **options)
      reached = true
      case change
      when :account, :endpoint then fixture.program.live_sessions = replacement
      when :closure then native.close_local(:left, confirmed: true)
      when :read_error then raise IOError, 'Local projection failed'
      end
      value
    end
    if change == :read_error
      assert_raises(IOError) { lobby.current_table_for('Bob') }
    else
      assert_equal(nil, lobby.current_table_for('Bob'), "Late #{change} escaped the current-room guard")
    end
    assert(reached, 'The intended post-projection boundary was not exercised')
    assert_equal(calls, fixture.calls.length, 'Late invalidation performed a server request')
    fixture.store.singleton_class.send(:remove_method, :project_room_records)
    fixture.program.live_sessions = fixture.endpoint
    if change == :closure
      assert_equal(nil, lobby.current_table_for('Bob'))
    else
      assert_equal(41, lobby.current_table_for('Bob').fetch('__id'), 'Rejected projection destroyed the original valid visit')
    end
  end
end

puts 'PASS independent current-room real projection: native endpoints, normal lobby, lower-ID replacement, warm no-I/O, one-table guard, late identity/closure/error'
