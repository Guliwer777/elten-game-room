require_relative '../support/native_room_harness'
require_relative '../../games/tic_tac_toe'
require_relative '../../lib/saved_games'

class ActorShapeArchiveStorage
  def initialize; @state = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@state)); end
  def update_json(_path, default:); yield(@state); end
end

game = GameRoomGames::TicTacToe.new
h = NativeRoomHarness.new(game: game, users: %w[123 Bob])
h.start
h.submit('123', game.legal_actions(h.replay('123'), '123').first)
boundary = h.transports['123'].freeze_game(h.session)
snapshot = h.repositories['123'].snapshot_for(h.session)
storage = ActorShapeArchiveStorage.new
saves = SavedGames.new(storage, owner: '123')
original = saves.put(game: game, table: h.table, snapshot: snapshot,
  repository: h.repositories['123'], now: boundary.created_at)
assert(original.fetch('events').first.fetch('actor') == '123', 'Native numeric login was not stored as text')
assert(saves.validate(original, game: game) == original, 'Valid numeric login archive failed validation')

[123, 123.0, [], ['123'], {}, {'name' => '123'}, true, false, nil].each do |actor|
  row = JSON.parse(JSON.generate(original))
  row.fetch('events').first['actor'] = actor
  row['checksum'] = saves.send(:checksum, row)
  before = JSON.generate(row)
  [:validate, :restored_data].each do |operation|
    args = {game: game}
    args.merge!(table_id: h.table['__id'] + 1, now: original['saved_at'] + 100) if operation == :restored_data
    error = assert_raises(ArgumentError) { saves.public_send(operation, row, **args) }
    assert(error.message == 'Invalid saved event', "#{operation} did not reject actor at the event boundary")
    assert(JSON.generate(row) == before, 'Invalid actor was silently converted or removed')
  end
end
assert(SavedGames.new(storage, owner: '123').list == [original], 'Rejected input changed the durable ordinary archive')

# Restore the valid, digit-only account through the actual native transport,
# not only through the archive mapper, and continue on the second client.
restored = NativeRoomHarness.new(game: game, users: %w[123 Bob])
data = saves.restored_data(original, game: game, table_id: restored.table['__id'], now: original['saved_at'] + 100)
session = restored.as('123') do
  restored.repositories['123'].restore_session(table: restored.table, game: game.id,
    players: data[:players], options: original['options'], restore: data)
end
repo = restored.repositories['123']
current = repo.snapshot_for(session)
replay = game.replay(current.session, current.events, repo)
assert(replay.accepted_events.length == 1 && replay.current_player == 'Bob', 'Valid numeric login restore changed the game')
assert(current.events.first['actor'] == '123', 'Restoration coerced the native string actor')
restored.instance_variable_set(:@session, session)
restored.submit('Bob', game.legal_actions(restored.replay('Bob'), 'Bob').first)
restored.assert_converged('digit-only login after native restore', expected_count: 2)
puts 'PASS saved actor shapes: native numeric login, typed invalid-event refusals, unchanged archive, cold restore and next move'
