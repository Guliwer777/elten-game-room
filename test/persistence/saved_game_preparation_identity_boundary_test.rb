require_relative '../support/saved_game_preparation_contract'

def unfinished_preparation
  app, broker, saved, guests = SavedPreparationContract.fixture
  SavedPreparationContract.role_failure(app, :before)
  assert(app.send(:create_saved_game_table, saved).nil?, 'Fixture did not interrupt its role write')
  [app, broker, saved, guests, app.lobby.current_table_for('Alice')]
end

app, broker, saved, guests, old = unfinished_preparation
app.lobby.close_table(old)
retained = app.lobby.create_table(name: saved['table_name'], game: saved['game'], owner: 'Alice',
  game_options: saved['options'], resume_save_id: saved['id']).table
baseline = SavedPreparationContract.core_state(broker, retained)
reused = app.send(:create_saved_game_table, saved)
assert(reused && reused['__id'] == retained['__id'], 'Existing same-save table was not reusable')
assert(SavedPreparationContract.core_state(broker, retained) == baseline && app.notices.grep(Array).empty?,
  'Old preparation was applied to a different native room with the same archive ID')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(retained)

# Leave and rejoin the very same room, then return ownership to the archive
# owner. Its IDs match, but it is no longer the original visit/preparation.
app, broker, saved, guests, row = unfinished_preparation
bob = guests.first
discovered = bob.discover_rooms.find { |item| item['__id'] == row['__id'] }
assert(bob.establish_membership(table_id: row['__id'], owner: 'Alice', capacity: 8, user: 'Bob', table: discovered),
  'Bob could not retain the preparation room')
before_token = app.transport.membership_token(row['__id'])
assert(app.lobby.leave_table(row, 'Alice') == :left, 'Archive owner did not leave normally')
discovered = app.transport.discover_rooms.find { |item| item['__id'] == row['__id'] }
assert(app.transport.establish_membership(table_id: row['__id'], owner: 'Bob', capacity: 8,
  user: 'Alice', table: discovered), 'Archive owner did not rejoin normally')
bob.transfer_room_owner(row, 'Alice')
assert(app.transport.membership_token(row['__id']) != before_token, 'Fixture reused its old native attachment')
current = app.lobby.snapshot_for(row, force: true).table
baseline = SavedPreparationContract.core_state(broker, current)
assert(app.send(:create_saved_game_table, saved)['__id'] == row['__id'], 'Rejoined continuation was not returned')
assert(SavedPreparationContract.core_state(broker, current) == baseline && app.notices.grep(Array).empty?,
  'Preparation intent survived leaving and rejoining the same native room')
app.lobby.close_table(current)

# Account changes also invalidate the pending setup. Returning to Alice may
# reuse the current table, but must not silently reactivate her old intention.
app, broker, saved, guests, row = unfinished_preparation
bob = guests.first
discovered = bob.discover_rooms.find { |item| item['__id'] == row['__id'] }
assert(bob.establish_membership(table_id: row['__id'], owner: 'Alice', capacity: 8, user: 'Bob', table: discovered),
  'Second account did not enter fixture')
baseline = SavedPreparationContract.core_state(broker, row)
$game_room_test_user = 'Bob'
app.send(:create_saved_game_table, saved)
$game_room_test_user = 'Alice'
app.send(:create_saved_game_table, saved)
assert(SavedPreparationContract.core_state(broker, row) == baseline && app.notices.grep(Array).empty?,
  'Changing the account did not invalidate pending preparation')
app.lobby.close_table(row)

# Identity can change between the first current-room check and the managed
# worker. It must be rechecked before role activation or invitation delivery.
app, broker, saved, guests, old = unfinished_preparation
other = nil
baseline = nil
app.before_prepare = lambda do
  app.lobby.close_table(old)
  other = app.lobby.create_table(name: 'Retained replacement room', game: saved['game'], owner: 'Alice',
    game_options: saved['options'], resume_save_id: saved['id']).table
  baseline = SavedPreparationContract.core_state(broker, other)
end
result = app.send(:create_saved_game_table, saved)
assert(other && result.nil?, 'Retry did not perform its final preparation identity check')
assert(SavedPreparationContract.core_state(broker, other) == baseline && app.notices.grep(Array).empty?,
  'Managed worker applied an old preparation to the replacement room')
assert(app.send(:create_saved_game_table, saved)['__id'] == other['__id'] &&
  SavedPreparationContract.core_state(broker, other) == baseline, 'Invalidated intent mutated the retained room on another retry')
SavedPreparationContract.unchanged_archive(app, saved)
app.lobby.close_table(other)

puts 'Saved continuation preparation stays bound to its archive, account, native room and original membership OK'
