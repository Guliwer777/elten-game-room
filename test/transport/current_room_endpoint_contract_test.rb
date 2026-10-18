require_relative '../support/consumed_discovery_invitation'
require_relative '../../lib/lobby_repository'

def with_current_room_endpoint
  with_consumed_invitation do |fixture|
    # Room projection is unrelated to the native membership boundary. Keep
    # current_room, LobbyRepository, transport and SDK Sessions unmodified.
    fixture.store.define_singleton_method(:table_for) { |id, **_options| fixture.table(id) }
    fixture.store.define_singleton_method(:room_snapshot) do |row, **_options|
      id = row.is_a?(Hash) ? row.fetch('__id') : row
      native = send(:active_session, id)
      {table: fixture.table(id), members: native.participants.map(&:user), bots: [], observers: []}
    end
    transport = GameRoomTransport.new(fixture.program)
    transport.instance_variable_set(:@live_store, fixture.store)
    lobby = LobbyRepository.new(fixture.program, transport: transport)
    fixture.deliver
    assert_equal(:joined, lobby.join_table(fixture.table, 'Bob').status)
    yield fixture, lobby
  end
end

['Bob', 'Other'].product([41, 42]).each do |user, destination|
  with_current_room_endpoint do |fixture, lobby|
    old = fixture.endpoint.sessions.fetch(0)
    token = fixture.store.membership_token(41)
    replacement = fixture.build_endpoint(user)
    fixture.program.live_sessions = replacement
    count = fixture.calls.length
    assert_equal(nil, lobby.current_table_for(user), 'Another endpoint supplied current membership')
    assert_equal(count, fixture.calls.length, 'A current-table read performed discovery/join')
    assert(!old.closed?, 'Checking the new endpoint left an accepted old visit')
    assert(fixture.store.send(:active_session, 41).equal?(old), 'Read rewrote the old attachment')

    result = lobby.join_table(fixture.table(destination), user)
    assert_equal(:joined, result.status, "Current-room shortcut bypassed join: #{user}/#{destination}")
    native = replacement.sessions.fetch(0)
    assert(fixture.store.send(:active_session, destination).equal?(native), 'Current SDK visit is not attached')
    assert(!token.equal?(fixture.store.membership_token(destination)), 'New visit retained its old token')
    assert_equal(destination, lobby.current_table_for(user).fetch('__id'))
    assert_equal(nil, lobby.current_table_for(user == 'Bob' ? 'Other' : 'Bob'), 'Foreign account was reported as current')
    calls = fixture.calls.length
    assert_equal(:already_here, lobby.join_table(fixture.table(destination), user).status)
    assert_equal(calls, fixture.calls.length, 'Actual same-endpoint reopen repeated the join')
  end
end

[:sessions, :projection].product(['Bob', 'Other']).each do |boundary, user|
  with_current_room_endpoint do |fixture, lobby|
    original = fixture.endpoint
    next_endpoint = fixture.build_endpoint(user)
    calls = fixture.calls.length
    switches = 0
    object, method = boundary == :sessions ? [original, :sessions] : [fixture.store, :table_for]
    original_method = object.method(method)
    object.define_singleton_method(method) do |*args, **keywords|
      result = original_method.call(*args, **keywords)
      fixture.program.live_sessions = next_endpoint
      switches += 1
      result
    end
    assert_equal(nil, lobby.current_table_for('Bob'), "Old projection escaped after endpoint change: #{boundary}/#{user}")
    assert(switches.positive?, 'Endpoint injection was not reached')
    assert_equal(calls, fixture.calls.length, 'Reading a superseded membership performed a write')
    object.define_singleton_method(method, original_method)
    fixture.program.live_sessions = original
    assert_equal(41, lobby.current_table_for('Bob').fetch('__id'), 'Returning to the actual accepted visit lost it')
  end
end

with_current_room_endpoint do |fixture, lobby|
  native = fixture.endpoint.sessions.fetch(0)
  original = fixture.store.method(:table_for)
  fixture.store.define_singleton_method(:table_for) do |*args, **options|
    result = original.call(*args, **options)
    native.close_local(:left, confirmed: true)
    result
  end
  assert_equal(nil, lobby.current_table_for('Bob'), 'A visit closed during projection was still current')
end

puts 'PASS current-room native endpoint contract: lobby join/reopen, own account, no cross-table block, late provider change, closed visit and zero write reads'
