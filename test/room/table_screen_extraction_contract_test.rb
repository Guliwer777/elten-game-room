require_relative '../support/room_interface'

def extraction_room_app
  row = {'__id'=>7, 'owner'=>'Alice', 'game'=>'four_in_a_row', 'status'=>'waiting',
    'max_players'=>8, 'name'=>'Extraction boundary', 'game_options'=>'{}'}
  room = LobbyRepository::TableSnapshot.new(table: row, members: %w[Alice Bob], bots: [])
  state = GameRoomLifecycle::State.new(room: room, game: GameRoomGames::FourInARow.new,
    game_snapshot: nil, replay: nil)
  app = EltenGameRoom.allocate
  app.instance_variable_set(:@lobby, LobbyRepository.allocate)
  app.instance_variable_set(:@games, InterfaceGameRepository.new)
  app.instance_variable_set(:@transport, Object.new)
  previous = Object.new
  app.instance_variable_set(:@table_network_view, previous)
  tracker = Object.new
  tracker.define_singleton_method(:observe) { |_| [] }
  app.define_singleton_method(:room_membership_tracker) { |_| tracker }
  app.define_singleton_method(:play_game_sounds) { |_| }
  app.define_singleton_method(:announce_new_table_activity) { |_, after_id:| after_id }
  app.define_singleton_method(:room_history_items) { |_, _| [] }
  app.define_singleton_method(:load_room_state) { |*_args, **_options| state }
  [app, row, previous]
end

# Returning a newly constructed layout from an extracted helper must not lose
# its cleanup ownership if a later presentation step raises before the return.
app, row, previous = extraction_room_app
original_new = GameRoomLayout::Screen.method(:new)
created = nil
cleanups = 0
GameRoomLayout::Screen.define_singleton_method(:new) do |**options|
  created = original_new.call(**options)
  original_cleanup = created.method(:begin_bindings)
  created.define_singleton_method(:begin_bindings) { cleanups += 1; original_cleanup.call }
  created.define_singleton_method(:session_id=) { |_| raise 'presentation failure' }
  created
end
begin
  app.send(:run_table_screen, row)
  raise 'Presentation failure was swallowed'
rescue RuntimeError => error
  raise unless error.message == 'presentation failure'
ensure
  GameRoomLayout::Screen.define_singleton_method(:new, original_new)
end
assert(created && cleanups == 1, 'New layout escaped cleanup when its presenter failed')
assert(app.instance_variable_get(:@table_layouts).empty?, 'Failed layout retained by the room')
assert(app.instance_variable_get(:@table_network_view).equal?(previous), 'Previous network view was not restored')

# A waiting-room command may open another native window. The monitor remains
# owned by run_table_screen until that command returns or raises.
app, row, previous = extraction_room_app
background = Object.new
closed = 0
background.define_singleton_method(:close) { closed += 1 }
background.define_singleton_method(:alive?) { false }
app.define_singleton_method(:start_waiting_table_background) { |*_args| background }
app.define_singleton_method(:start_new_game) do |_row|
  assert(closed.zero?, 'Monitor stopped before executing the room command')
  raise 'command failure'
end
Form.driver = lambda do |_form|
  app.instance_variable_get(:@table_layouts).fetch(7).primary_button.trigger(:press)
end
begin
  app.send(:run_table_screen, row)
  raise 'Command failure was swallowed'
rescue RuntimeError => error
  raise unless error.message == 'command failure'
ensure
  Form.driver = nil
end
assert(closed == 1, 'Waiting-room monitor was not closed exactly once')
assert(app.instance_variable_get(:@table_layouts).empty?, 'Room command failure retained its layout')
assert(app.instance_variable_get(:@table_network_view).equal?(previous), 'Command failure lost the previous view')
puts 'PASS table-screen extraction: layout cleanup before helper return and monitor ownership through room commands'
