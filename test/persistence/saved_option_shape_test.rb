require_relative '../support/native_room_harness'
require_relative '../../games/checkers'
require_relative '../../lib/saved_games'

class OptionShapeArchiveStorage
  def initialize; @state = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@state)); end
  def update_json(_path, default:); yield(@state); end
end

game = GameRoomGames::Checkers.new
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
h.start
h.submit('Alice', game.legal_actions(h.replay('Alice'), 'Alice').first)
boundary = h.transports['Alice'].freeze_game(h.session)
snapshot = h.repositories['Alice'].snapshot_for(h.session)
saves = SavedGames.new(OptionShapeArchiveStorage.new, owner: 'Alice')
original = saves.put(game: game, table: h.table, snapshot: snapshot, repository: h.repositories['Alice'], now: boundary.created_at)
assert(saves.validate(original, game: game) == original, 'Valid native archive control failed')

[true, false, {}, 1, 'teams', [{}, 0], [true, 0], [[0], 0]].each do |seats|
  row = JSON.parse(JSON.generate(original))
  options = JSON.parse(row['options']).merge('team_seats' => seats)
  row['options'] = JSON.generate(options)
  row['checksum'] = saves.send(:checksum, row)
  before = Marshal.dump(row)
  error = assert_raises(ArgumentError) { saves.validate(row, game: game) }
  assert(error.message == 'Invalid saved rules', 'Malformed archive failed outside the option boundary')
  assert(Marshal.dump(row) == before, 'Invalid archive was silently repaired')
end
assert(saves.list == [original], 'Invalid validation altered the persisted ordinary save')
restored = saves.restored_data(original, game: game, table_id: h.table['__id'] + 1, now: original['saved_at'] + 100)
assert(restored[:events].length == original['events'].length, 'Ordinary restoration lost its accepted move')
puts 'PASS saved option shapes: real native archive, valid checksum, controlled refusal without repair and unchanged ordinary restore'
