require_relative '../support/native_room_harness'
require_relative '../../games/axel_pong'
require_relative '../../games/checkers'
require_relative '../../games/scrabble'

game = GameRoomGames::AxelPong.new
options = game.default_options.merge('team_size' => 2, 'team_seats' => [0, 0, 1, 1])
h = NativeRoomHarness.new(game: game, options: options)
created = h.core.entries.find { |entry| entry['packet']['kind'] == 'room_created' }.fetch('packet')
h.start
start = h.core.entries.find { |entry| entry['packet']['kind'] == 'game_started' }.fetch('packet')
expected = h.replay('Bob').state
expected_summary = game.combined_options_summary(options)
assert(game.team_assignment(options, players: h.users).seats == [0, 0, 1, 1], 'Control lost the chosen doubles teams')

# Actual authenticated packets reach the native stack, then the production
# validator/projection must reject them before a game or lobby consumer runs.
invalid_seats = [true, false, 1, 'teams', {}, [{}, 0, 1, 1], [true, 0, 1, 1], [[0], 0, 1, 1]]
invalid_seats.each_with_index do |seats, index|
  text = JSON.generate(options.merge('team_seats' => seats))
  bad_start = JSON.parse(JSON.generate(start))
  bad_start['data'].merge!('session_id' => h.session['__id'] + index + 1, 'options' => text)
  bad_created = JSON.parse(JSON.generate(created))
  bad_created['data']['game_options'] = text
  bad_state = {'version' => 2, 'kind' => 'room_state', 'actor' => 'Alice', 'data' => {'game_options' => text}}
  [bad_start, bad_created, bad_state].each { |packet| h.view('Alice').stack_push(packet, message_id: SecureRandom.uuid) }
  h.users.each do |user|
    repo = h.repositories.fetch(user)
    current = repo.session_for_table(h.table, force: true)
    assert(current['__id'] == h.session['__id'], "Malformed seats replaced the active native game: #{seats.inspect}")
    snapshot = repo.snapshot_for(current)
    assert(game.replay(snapshot.session, snapshot.events, repo).state == expected, 'Rejected options altered the game')
    row = h.transports.fetch(user).room_snapshot(h.table).fetch(:table)
    assert(row['game_options'] == JSON.generate(options), 'Rejected room options silently changed doubles')
    assert(game.combined_options_summary(game.options_from_json(row['game_options'])) == expected_summary, 'Lobby summary changed after rejected options')
  end
end

# Initial public discovery and its explicit options refresh use different
# call paths. Neither may introduce a malformed row into the lobby.
reader = GameRoomTransport.new(ProgramDouble.new(h.broker.endpoint('Eve')))
published = JSON.parse(JSON.generate(h.core.discovery_metadata))
row = reader.discover_rooms.find { |item| item['__id'] == h.table['__id'] }
assert(row, 'Valid discovery control is missing')
invalid_seats.product([false, true]).each do |seats, compressed|
  text = JSON.generate(options.merge('team_seats' => seats))
  metadata = published.reject { |key, _| %w[game_options options_z].include?(key) }
  metadata.merge!(compressed ? {'options_z' => Base64.strict_encode64(Zlib::Deflate.deflate(text))} : {'game_options' => text})
  h.core.discovery_metadata = metadata
  assert(reader.discover_rooms.none? { |item| item['__id'] == h.table['__id'] }, 'Malformed options reached initial lobby rows')
  assert(reader.discovered_options(row)[:status] == :unavailable, 'Malformed options escaped explicit discovery validation')
end
h.core.discovery_metadata = published
assert(reader.discover_rooms.length == 1, 'Malformed discovery poisoned later valid refresh')
assert(h.broker.endpoint('Eve').sessions.empty?, 'Read-only discovery joined a room')

# Historical numeric/string/nil coercions keep their exact chosen teams.
legacy = [0.0, '0', 1.9, '1']
accepted = JSON.parse(JSON.generate(start))
accepted['data'].merge!('session_id' => h.session['__id'] + 100, 'options' => JSON.generate(options.merge('team_seats' => legacy)))
h.view('Alice').stack_push(accepted, message_id: SecureRandom.uuid)
current = h.repositories['Bob'].session_for_table(h.table, force: true)
assert(current['__id'] == accepted['data']['session_id'], 'Valid legacy start was lost after malformed records')
assert(game.options_from_json(current['options'])['team_seats'] == [0, 0, 1, 1], 'Legacy team coercion changed')
snapshot = h.repositories['Bob'].snapshot_for(current)
assert(game.replay(snapshot.session, snapshot.events, h.repositories['Bob']).players == h.users, 'Valid later replay failed')

# A wrong scalar type in an ordinary game must not raise in a remote replay.
[[GameRoomGames::Checkers, 'rules'], [GameRoomGames::Scrabble, GameRoomContent::PACK_VERSION_KEY]].each do |type, key|
  [nil, {}, true, false, []].each do |value|
    instance = type.new
    values = instance.default_options
    values[key] = value unless value.nil?
    room = NativeRoomHarness.new(game: instance, users: %w[Alice Bob], options: values)
    room.start
    snap = room.repositories['Bob'].snapshot_for(room.session)
    replay = instance.replay(snap.session, snap.events, room.repositories['Bob'])
    assert(replay.players == room.users, "Wrong scalar prevented #{instance.id} replay")
    if type == GameRoomGames::Scrabble && !value.nil?
      assert(instance.validation_error(instance.options_from_json(snap.session['options'])), 'Invalid content version became a valid content pack')
    end
  end
end
puts 'PASS native option shapes: authenticated record rejection, initial/explicit plain/compressed discovery, doubles, later replay and scalar normalization'
