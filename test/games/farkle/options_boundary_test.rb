require_relative '../../support/native_room_harness'
require_relative '../../../games/farkle'

game = GameRoomGames::Farkle.new
invalid_versions = [{}, true, [], [1], {'version' => 1}]
invalid_versions.each do |version|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  assert(h.replay('Bob').current_player == 'Alice', 'Valid Farkle control failed before the malformed packet')
  start = h.core.entries.find { |entry| entry['packet']['kind'] == 'game_started' }.fetch('packet')
  packet = JSON.parse(JSON.generate(start))
  options = game.default_options.merge('farkle_rules_version' => version)
  text = JSON.generate(options)
  packet['data'].merge!('session_id' => h.session['__id'] + 100, 'options' => text)
  h.view('Alice').stack_push(packet, message_id: SecureRandom.uuid)
  h.view('Alice').stack_push({'version' => 2, 'kind' => 'room_state', 'actor' => 'Alice',
    'data' => {'game_options' => text}}, message_id: SecureRandom.uuid)

  # The general wire schema permits game-specific scalars. Exercise the real
  # accepted projection and its consumers, not only a direct normalizer call.
  h.users.each do |user|
    repository = h.repositories.fetch(user)
    session = repository.session_for_table(h.table, force: true)
    assert(session['__id'] == packet['data']['session_id'], 'The packet did not reach the game-specific boundary')
    snapshot = repository.snapshot_for(session)
    replay = game.replay(snapshot.session, snapshot.events, repository)
    assert(replay.players == h.users && replay.accepted_events.empty?, 'Malformed version altered initial game state')
    assert(replay.state[:options]['farkle_rules_version'] == 0, 'Malformed version silently became a supported rules version')
    assert(game.validation_error(replay.state[:options]) == 'This Farkle rules version is not supported.', 'Malformed version lost its normal validation error')
    table = h.transports.fetch(user).room_snapshot(h.table).fetch(:table)
    assert(table['game_options'] == text, 'The test bypassed the accepted room-state consumer')
    assert(!game.combined_options_summary(game.options_from_json(table['game_options'])).empty?, 'Lobby summary is unavailable')
  end
  assert(JSON.generate(options) == text, 'Normalization mutated the input')
end

# Preserve the pre-existing string/symbol precedence, numeric coercion and
# difference between absent archive metadata (v1) and newly created games (v2).
[nil, false, 0, 1, 2, 3, -1, 1.9, 2.9, '', 'bad', '01', '2.9', ' 2 '].each do |value|
  expected = (value || 2).to_i
  ['farkle_rules_version', :farkle_rules_version].each do |key|
    source = {key => value}.freeze
    assert(game.normalize_options(source)['farkle_rules_version'] == expected, "Historical coercion changed: #{key}=#{value.inspect}")
  end
  assert(game.options_from_json(JSON.generate('farkle_rules_version' => value))['farkle_rules_version'] == expected, 'Archive scalar coercion changed')
end
assert(game.normalize_options('farkle_rules_version' => false, farkle_rules_version: 1)['farkle_rules_version'] == 1, 'Falsy string-key precedence changed')
assert(game.normalize_options('farkle_rules_version' => 2, farkle_rules_version: 1)['farkle_rules_version'] == 2, 'Truthy string-key precedence changed')
assert(game.options_from_json('{}')['farkle_rules_version'] == 1, 'Old archives no longer use rules version 1')
assert(game.options_from_json('broken JSON')['farkle_rules_version'] == 1, 'Historical malformed JSON fallback changed')
assert(game.new_game_options({})['farkle_rules_version'] == 2, 'New games no longer use rules version 2')

[1, 2].each do |version|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], options: game.default_options.merge('farkle_rules_version' => version))
  h.start
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    now: 1000, random_source: GameRoomRandom::SeededSource.new(7))
  h.submit('Alice', {'kind' => 'dice', 'action' => 'roll'}, context: context)
  h.assert_converged("normal Farkle version #{version}", expected_count: 1)
  assert(h.replay('Bob').state[:options]['farkle_rules_version'] == version, 'A normal server roll changed the rules version')
end
puts 'PASS Farkle hidden option boundary: native records/replay/lobby, unsupported shapes, legacy coercion and normal v1/v2 server rolls'
