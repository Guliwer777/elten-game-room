require_relative '../support/saved_games_ui'

# Keep the native lobby's CreateResult contract: a current membership may
# appear after the application's first check and before create_table.
class SavedGameCreationRaceDriver < SaveAppDriver
  attr_accessor :before_prepare

  def run_network_task(title, **options, &block)
    if title == 'Preparing saved game' && @before_prepare
      callback, @before_prepare = @before_prepare, nil
      callback.call
    end
    super(title, **options, &block)
  end
end

def saved_creation_fixture(observer_owner: false)
  broker = NativeLiveSessionsBroker.new
  app = SavedGameCreationRaceDriver.new(broker)
  $game_room_test_user = 'Alice'
  game = GameRoomGames::TicTacToe.new
  original = app.lobby.create_table(name: 'Original archive', game: game.id, owner: 'Alice').table
  names = observer_owner ? %w[Bob Carol] : %w[Bob]
  guests = names.map do |name|
    transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint(name)))
    selected = transport.discover_rooms.find { |row| row['__id'] == original['__id'] }
    assert(transport.establish_membership(table_id: original['__id'], owner: 'Alice', capacity: 8,
      user: name, table: selected), 'Fixture guest did not enter')
    transport
  end
  app.lobby.set_observer(original, 'Alice', true) if observer_owner
  players = observer_owner ? names : %w[Alice Bob]
  session = app.games.start_session(table: original, game: game.id, players: players,
    options: JSON.generate(game.default_options))
  saved = app.send(:saved_games).put(game: game, table: original,
    snapshot: app.games.snapshot_for(session), repository: app.games)
  app.lobby.close_table(original)
  [app, broker, saved, guests]
end

[false, true].each do |observer_owner|
  app, broker, saved, guests = saved_creation_fixture(observer_owner: observer_owner)
  other = nil
  app.before_prepare = lambda do
    other = app.lobby.create_table(name: 'Unrelated current table', game: 'uno', owner: 'Alice').table
  end
  before_notices = app.notices.length
  result = app.send(:create_saved_game_table, saved)
  assert(result.nil?, 'A table acquired during preparation was returned as the saved-game continuation')
  current = app.lobby.snapshot_for(other)
  assert(current.table['game'] == 'uno' && current.table['resume_save_id'].to_s.empty?,
    'The unrelated table metadata was changed')
  assert(!current.observer?('Alice'), 'Saved-game preparation changed the role at an unrelated table')
  assert(app.notices.drop(before_notices).none? { |notice| notice.is_a?(Array) },
    'Original saved-game players were invited to an unrelated table')
  assert(app.notices.drop(before_notices).include?('You are already at another table.'),
    'The conflicting membership was not explained')
  assert(app.send(:saved_games).fetch(saved['id']) == saved, 'The refused preparation consumed its archive')
  app.lobby.close_table(other)
end

app, broker, saved, guests = saved_creation_fixture
same = nil
app.before_prepare = lambda do
  same = app.lobby.create_table(name: saved['table_name'], game: saved['game'], owner: 'Alice',
    game_options: saved['options'], resume_save_id: saved['id']).table
end
before_count = broker.cores.length
result = app.send(:create_saved_game_table, saved)
assert(result && result['__id'] == same['__id'], 'An already acquired matching continuation was not reused')
assert(broker.cores.length == before_count + 1, 'Concurrent matching continuation created another native table')
assert(app.notices.none? { |notice| notice.is_a?(Array) }, 'Reusing the continuation resent invitations')
app.lobby.close_table(same)

app, broker, saved, guests = saved_creation_fixture
endpoint = broker.endpoint('Alice')
native_create = endpoint.method(:create)
failed_view = nil
endpoint.define_singleton_method(:create) do |**arguments|
  failed_view = native_create.call(**arguments)
  failed_view.define_singleton_method(:stack_push) { |*_args, **_options| raise EltenAPI::LiveSessions::TimeoutError, 'Initial table record failed' }
  failed_view
end
before_count = broker.cores.length
result = app.send(:create_saved_game_table, saved)
assert(result.nil? && app.errors.any? { |error| error.message == 'Initial table record failed' },
  'A real failure after native creation was not reported')
assert(broker.cores.length == before_count + 1 && failed_view.closed?,
  'Failed fresh native creation left a live incomplete table')
assert(app.lobby.current_table_for('Alice').nil?, 'Failed creation left a usable current-table reference')
assert(app.notices.none? { |notice| notice.is_a?(Array) }, 'Failed creation sent continuation invitations')
assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Failed creation consumed its archive')
endpoint.define_singleton_method(:create) { |**arguments| native_create.call(**arguments) }
retried = app.send(:create_saved_game_table, saved)
assert(retried && retried['resume_save_id'] == saved['id'], 'Fresh creation did not recover after the native failure')
assert(app.notices.count { |notice| notice.is_a?(Array) && notice.first == 'Bob' } == 1,
  'The recovered continuation did not send exactly one invitation')
assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Preparing the recovered continuation consumed its archive')
app.lobby.close_table(retried)

puts 'Saved-game creation revalidates native CreateResult: unrelated membership, observer owner, and same-save reuse OK'
