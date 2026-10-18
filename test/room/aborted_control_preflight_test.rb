require_relative "../support/table_lifecycle_controls_2"

$game_room_test_user = 'Alice'
broker = NativeLiveSessionsBroker.new
app = LifecycleApp.new(broker)
game = GameRoomGames::Battleship.new
table = app.lobby.create_table(name: 'Aborted private game', game: game.id, owner: 'Alice',
  game_options: JSON.generate(game.default_options)).table
bob = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Bob')))
bob.join_room(table, 'Bob')
session = app.games.start_session(table: table, game: game.id, players: %w[Alice Bob],
  options: table['game_options'])
before = broker.cores.values.first.last_seq
assert(!app.send(:change_table_control, table, :transfer_master, 'Bob'), 'Playable private state was transferred')
assert(broker.cores.values.first.last_seq == before, 'Private preflight rejection wrote a record')
assert(app.transport.abort_game(session), 'Fixture abort failed')
state = app.send(:load_room_state, table, title: 'test', force: true)
assert(state.waiting? && state.session['__aborted'] && state.session['__frozen'], 'Fixture is not an aborted waiting room')
assert(game.controller_change_error(state.replay), 'Fixture no longer retains a private replay')
before = broker.cores.values.first.last_seq
assert(!app.send(:change_table_control, table, :replace_player, 'Bob', replacement: :new_bot), 'Aborted seats remained replaceable')
assert(app.notices.last == 'Game paused.' && broker.cores.values.first.last_seq == before, 'Aborted replacement was not rejected before mutation')
assert(app.send(:change_table_control, table, :transfer_master, 'Bob'), 'Aborted private replay blocked the allowed waiting-room handover')
assert(app.lobby.snapshot_for(table).table['owner'] == 'Bob', 'Native owner did not change')
assert(app.games.session_for_table(table)['__aborted'], 'Handover resumed the aborted game')
puts 'Control preflight: active private transfer rejected, aborted replacement rejected, aborted waiting-room host transfer succeeds through native guard.'
