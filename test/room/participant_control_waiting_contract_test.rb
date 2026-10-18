require_relative '../support/room_interface'
require_relative '../support/native_room_harness'
require_relative '../../games/battleship'

# Exercise the actual waiting-room bindings without starting a second
# background runner. The native table/repository and lifecycle are unchanged.
class ControlWaitingTransport
  def initialize(native); @native = native; end
  def live_store?; false; end
  def method_missing(name, *arguments, **options, &block)
    @native.public_send(name, *arguments, **options, &block)
  end
  def respond_to_missing?(name, include_private = false)
    @native.respond_to?(name, include_private)
  end
end

h = NativeRoomHarness.new(game: GameRoomGames::Battleship.new, users: %w[Alice Bob])
h.start
h.as('Alice') { assert(h.transports['Alice'].abort_game(h.session), 'Fixture abort failed') }
app = EltenGameRoom.allocate
app.instance_variable_set(:@lobby, LobbyRepository.allocate)
app.instance_variable_set(:@games, h.repositories['Alice'])
app.instance_variable_set(:@transport, ControlWaitingTransport.new(h.transports['Alice']))
app.instance_variable_set(:@table_activity, TableActivityRepository.new(server_tables: {}, transport: h.transports['Alice']))
tracker = Object.new
tracker.define_singleton_method(:observe) { |_| [] }
app.define_singleton_method(:room_membership_tracker) { |_| tracker }
app.define_singleton_method(:play_game_sounds) { |_| }
app.define_singleton_method(:announce_new_table_activity) { |_, after_id:| after_id }
app.define_singleton_method(:announce_server_table_access) {}
app.define_singleton_method(:leave_table_from_screen) { |_| true }
app.define_singleton_method(:activate_table_transport) { |_| true }
denials = []
app.define_singleton_method(:alert) { |message| denials << message }
snapshot = h.repositories['Alice'].snapshot_for(h.session)
room = LobbyRepository::TableSnapshot.new(**h.transports['Alice'].room_snapshot(h.table))
room.table['tournament_match'] = {}
state = GameRoomLifecycle::State.new(room: room, game_snapshot: snapshot, game: h.game,
  replay: h.game.replay(snapshot.session, snapshot.events, h.repositories['Alice']), players: %w[Alice Bob])
assert(state.waiting? && h.game.controller_change_error(state.replay), 'Fixture did not retain a private replay after abort')
app.define_singleton_method(:load_room_state) { |*_arguments, **_options| state }
calls = []
app.define_singleton_method(:change_table_control) { |*arguments| calls << arguments }
visits = 0
Form.driver = lambda do |_form|
  visits += 1
  raise 'Waiting-room menu did not exit' if visits > 2
  layout = app.instance_variable_get(:@table_layouts).fetch(h.table['__id'])
  native = h.broker.endpoint('Alice').sessions.first
  network_calls = native.calls.dup
  layout.users.index = 1
  menu = FakeMenu.new
  layout.users.context(menu, false)
  assert(menu.options.none? { |entry| entry[2] == 'R' }, 'Waiting room exposed an aborted seat')
  transfer = menu.options.find { |entry| entry[2] == 'm' }
  assert(transfer, 'Waiting-room provider hid transfer because it retained a private replay')
  assert(GameRoomContextHelp.field_tips(layout.users).one? { |tip| tip.include?('Ctrl+M') }, 'Waiting-room help lost transfer')
  if visits == 1
    state.session['__control_ready'] = false
    transfer.last.call
    assert(calls.empty? && denials == ['This action is not available now.'], 'Old waiting-room menu bypassed unready control')
    state.session['__control_ready'] = true
    transfer.last.call
  else
    layout.back_button.trigger(:press)
  end
  assert(native.calls == network_calls, 'The waiting-room menu/help fetched state from the network')
end
h.as('Alice') { app.send(:run_table_screen, h.table) }
assert(calls.length == 1 && calls.first[1..] == [:transfer_master, 'Bob'], 'Waiting room dispatched the wrong control action')
puts 'PASS waiting-room provider: aborted private replay, host handover, hidden old-seat replacement, dynamic help and stale control refusal.'
