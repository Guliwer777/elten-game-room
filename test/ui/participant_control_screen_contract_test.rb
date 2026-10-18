require_relative '../support/background_help_game_screen'
require_relative '../../games/uno'

h, screen = screen_fixture(GameRoomGames::Uno.new, manage_observer: ->(*) {})
room = LobbyRepository::TableSnapshot.new(**h.transports['Alice'].room_snapshot(h.table))
screen.instance_variable_set(:@room_snapshot, room)
session = screen.instance_variable_get(:@session)
session['__tournament_match'] = {}
replay = h.replay('Alice')
replay.state[:private_cards] = {}
layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
  user_items: RoomPresentation.user_rows(room.members, owner: 'Alice', players: %w[Alice Bob], active: true))
wait = Struct.new(:action, :replay).new(nil, replay)
screen.send(:bind_wait_participants, wait, layout, -> {})
denials = []
screen.define_singleton_method(:alert) { |text| denials << text }
layout.users.index = 1
menu_for = lambda do
  menu = FakeMenu.new
  layout.users.context(menu, false)
  menu
end
initial = h.core.entries.length
native = h.broker.endpoint('Alice').sessions.first
initial_calls = native.calls.dup
menu = menu_for.call
assert(menu.options.none? { |entry| entry[2] == 'R' }, 'GameScreen did not supply its private replay/session to the menu')
assert(menu.options.one? { |entry| entry[2] == 'm' }, 'GameScreen hid the permitted host transfer')
assert(GameRoomContextHelp.field_tips(layout.users).none? { |tip| tip.include?('Ctrl+Shift+R') }, 'GameScreen help disagrees with the menu')

replay.state.delete(:private_cards)
replacement = menu_for.call.options.find { |entry| entry[2] == 'R' }
assert(replacement, 'GameScreen did not expose the existing public replacement capability')
session['__frozen'] = true
replacement.last.call
assert(wait.action.nil? && denials == ['This action is not available now.'], 'A retained shortcut ignored a newer paused session')
assert(menu_for.call.options.none? { |entry| ['R', 'm'].include?(entry[2]) }, 'Paused controls remain visible')
session.delete('__frozen')
replacement.last.call
assert(wait.action == :replace_player && screen.instance_variable_get(:@selected_participant) == 'Bob', 'Re-enabled menu lost its selected player')
assert(h.core.entries.length == initial, 'A menu/help read wrote to the native stack')
assert(native.calls == initial_calls, 'Menu/help construction caused a network operation')
puts 'PASS active GameScreen provider: session-only binding, private/public replay, pause, stale shortcut refusal and retained participant.'
