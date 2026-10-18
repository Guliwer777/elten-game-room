require_relative "../support/table_lifecycle_controls_2"

broker = NativeLiveSessionsBroker.new
$game_room_test_user = 'Alice'
app = LifecycleApp.new(broker)
table = app.lobby.create_table(name:'Control UI',game:'four_in_a_row',owner:'Alice',game_options:'{}').table
bob = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Bob')))
bob.join_room(table,'Bob')
watcher = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Watcher')))
watcher.join_room(table,'Watcher')
app.lobby.set_observer(table,'Watcher',true)
session = app.games.start_session(table:table,game:'four_in_a_row',players:%w[Alice Bob],options:'{}')
assert(app.send(:change_table_control,table,:replace_player,'Bob', replacement: :new_bot), 'Owner action not wired to transport')
bot = app.games.session_for_table(table)['__players'].last
assert(GameRoomParticipants.bot?(bot), 'UI did not replace the seat')
assert(app.send(:change_table_control,table,:replace_player,bot,replacement: 'Bob'), 'UI did not restore the player')
assert(app.games.session_for_table(table)['__players']==%w[Alice Bob], 'Restored UI control lost')
assert(!app.send(:change_table_control,table,:replace_player,'Alice',replacement: 'Bob'), 'UI allowed swapping two occupied places')
assert(app.games.session_for_table(table)['__players']==%w[Alice Bob], 'Rejected replacement changed places')
assert(app.send(:change_table_control,table,:transfer_master,'Watcher'), 'UI could not transfer to observer')
assert(app.lobby.snapshot_for(table).table['owner']=='Watcher', 'UI transfer not confirmed')
assert(!app.send(:change_table_control,table,:replace_player,'Bob'), 'Former owner kept management rights')
assert(app.games.session_for_table(table)['__players']==%w[Alice Bob], 'Former owner mutated replacement')

# A private-data stage explains the restriction before any server mutation.
private_game = GameRoomGames::Battleship.new
room = LobbyRepository::TableSnapshot.new(table:table.merge('owner'=>'Alice'),members:%w[Alice Bob],bots:[],observers:[])
replay = Struct.new(:state) { def finished?; false; end }.new({phase: :playing})
state = Struct.new(:game,:replay,:room,:session).new(private_game,replay,room,{'__id' => 'private-fixture'})
app.define_singleton_method(:load_room_state) { |*_args, **_options| state }
seq = broker.cores.values.first.last_seq
assert(!app.send(:change_table_control,table,:transfer_master,'Bob'), 'Private game was silently handed over')
assert(app.notices.last == 'The current game contains private data that cannot be transferred at this stage.', 'No explanation for private phase')
assert(broker.cores.values.first.last_seq==seq, 'Rejected private transfer wrote server state')
puts 'Table-control application actions: replace, restore, observer master, stale rights and private-phase notice: OK'
entries = GameRoomParticipantMenu.entries
assert(entries.none? { |entry| entry.action == :replace_player }, 'Replacement is still global')
assert(GameRoomParticipantMenu.replacement_entry.help_key == 'Ctrl+Shift+R', 'Replacement shortcut changed')
assert(entries.none? { |entry| entry.action == :transfer_master }, 'Master transfer is still global')
