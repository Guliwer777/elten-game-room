require_relative '../support/consumed_discovery_invitation'

fixture = ConsumedDiscoveryInvitationFixture.new
checks = 0
begin
  original = fixture.method(:discovery)
  make = lambda do |id, metadata = nil|
    original.call(id).merge('visibility' => 'public', 'capacity' => 8, 'participant_count' => 1,
      'created_at' => 0, 'limits' => {'discovery_refresh' => true},
      'discovery_metadata' => metadata || fixture.metadata(id).merge('owner' => 'Alice',
        'name' => "table-#{id}", 'game_options' => '{}', 'created_at' => 100,
        'max_players' => 8, 'bot_count' => 0, 'player_count' => 1))
  end
  rows = [make.call(40), make.call(41), make.call(42)]
  requests = []
  fixture.endpoint.define_singleton_method(:discover_sessions) do |**options|
    requests << [:discover, options]
    EltenAPI::LiveSessions::DiscoveryPage.new(self, {'items' => rows})
  end
  fixture.endpoint.define_singleton_method(:refresh_discovered_session) do |id, _token, **_options|
    requests << [:refresh, id]
    rows.find { |row| row['id'] == id } || raise('Unknown fixture room')
  end
  metadata = rows[1].fetch('discovery_metadata')
  read = -> { fixture.store.discover_rooms.sort_by { |row| row['__id'] } }
  selected = read.call.fetch(1)
  assert(selected.fetch('__discovered_session').is_a?(EltenAPI::LiveSessions::DiscoveredSession), 'The fixture omitted the native discovery path')
  assert(fixture.store.discovered_options(selected) == {status: :ready, game: 'tic_tac_toe', options: '{}'}, 'Valid explicit discovery failed')

  malformed = %w[protocol created_at max_players bot_count player_count].flat_map do |field|
    [true, false, [], {}, [1], {'n' => 1}].filter_map do |value|
      [field, value] unless field == 'max_players' && value == false
    end
  end
  malformed.each do |field, value|
    rows = [make.call(40), make.call(41, metadata.merge(field => value)), make.call(42)]
    before = JSON.generate(rows)
    request_count = requests.length
    assert(read.call.map { |row| row['__id'] } == [40, 42], "Malformed #{field} hid a valid neighboring room")
    assert(requests.length == request_count + 1, 'Validation added a discovery request')
    assert(fixture.store.send(:discover_item, 42)&.id == 'native-room-42', 'Join lookup stopped at a malformed neighbor')
    assert(fixture.store.discovered_options(selected) == {status: :unavailable}, 'Explicit refresh accepted malformed metadata')
    assert(JSON.generate(rows) == before, 'Validation mutated the server description')
    checks += 1
  end
  [nil, false, true, 7, 7.5, 'invalid', [], [1], {'unknown' => 1}].each do |value|
    rows = [make.call(40), make.call(41).merge('discovery_metadata' => value), make.call(42)]
    before = JSON.generate(rows)
    assert(read.call.map { |row| row['__id'] } == [40, 42], 'An invalid metadata map hid valid neighbors')
    assert(fixture.store.send(:discover_item, 42)&.id == 'native-room-42', 'Lookup dereferenced an invalid metadata map')
    assert(fixture.store.discovered_options(selected) == {status: :unavailable}, 'Refresh dereferenced an invalid metadata map')
    assert(JSON.generate(rows) == before, 'Outer-map validation changed source data')
    checks += 1
  end

  # Keep historical scalar coercions and the distinction between missing and
  # explicit nil. Native capacity/date overrides remain authoritative.
  [GameRoomLiveSessionStore::PROTOCOL, GameRoomLiveSessionStore::PROTOCOL.to_s,
    GameRoomLiveSessionStore::PROTOCOL.to_f].each do |value|
    rows = [make.call(41, metadata.merge('protocol' => value))]
    assert(read.call.one? && read.call.first['__discovery_protocol'] == value.to_i, 'Valid protocol scalar was lost')
    checks += 1
  end
  %w[created_at max_players bot_count player_count].product([nil, 0, 3, -4, 3.75, '6', '3legacy', '']).each do |field, value|
    values = metadata.merge(field => value)
    row = fixture.store.send(:table_from_metadata, values, 41)
    expected = if field == 'created_at'
      value.to_i
    elsif field == 'max_players'
      [[(value || GameRoomLiveSessionStore::MAX_CAPACITY).to_i, 2].max, GameRoomLiveSessionStore::MAX_CAPACITY].min
    else
      [[value.to_i, 0].max, GameRoomLiveSessionStore::MAX_CAPACITY].min
    end
    assert(row.fetch(field) == expected, "Legacy #{field} scalar changed: #{value.inspect}")
    rows = [make.call(41, values)]
    assert(read.call.one?, 'Valid scalar description disappeared from native discovery')
    checks += 1
  end
  legacy = metadata.reject { |key, _| %w[created_at max_players bot_count player_count].include?(key) }
  rows = [make.call(41, legacy)]
  row = read.call.fetch(0)
  assert(row.values_at('created_at', 'max_players', 'bot_count', 'player_count') == [0, 8, 0, 1], 'Missing legacy metadata defaults changed')
  assert(fixture.store.send(:table_from_metadata, metadata.merge('max_players' => false), 41)['max_players'] == 8, 'Legacy false capacity no longer means the default')
  rows = [make.call(41, metadata.merge('created_at' => 50, 'max_players' => 2)).merge('created_at' => 500, 'capacity' => 6)]
  assert(read.call.first.values_at('created_at', 'updated_at', 'max_players') == [500, 500, 6], 'Native date/capacity lost precedence')
  rows = [make.call(40), make.call(41), make.call(42)]
  assert(read.call.map { |item| item['__id'] } == [40, 41, 42], 'Valid later discovery remained poisoned')
  assert(fixture.store.discovered_options(selected)[:status] == :ready, 'Explicit discovery failed to recover')
  assert(fixture.endpoint.sessions.empty? && fixture.calls.empty?, 'Read-only discovery joined or wrote to a room')
  checks += 5
ensure
  fixture.close
end
puts "PASS discovery metadata: #{checks} native shape, neighbor, refresh, coercion, defaults and no-I/O-side-effect checks"
