require_relative '../support/background_help_game_screen'

# Retained UI actions are deliberately injected after the screen has read a
# real native session. This is not a menu-presence or source-string assertion.
[:table, :session].each do |marker_location|
  calls, history_exports = [], []
  h, screen = screen_fixture(GameRoomGames::FourInARow.new,
    save_game: ->(*args) { calls << args; true },
    save_table_history: ->(entries) { history_exports << entries })
  screen.instance_variable_get(:@table)['tournament_match'] = {} if marker_location == :table
  initial_events = h.events('Alice')
  initial_stack = h.broker.cores.fetch(h.table['__live_session_id']).entries.length
  spoken_start = $spoken_messages.length
  actions = [:save_game, :save_table_history, :back]
  screen.define_singleton_method(:wait_for_action) do |_replay, _revision|
    # The received session may reveal a tournament binding after an older
    # unmarked screen had already registered its save action.
    @session['__tournament_match'] = {} if marker_location == :session
    actions.shift || raise('The blocked save did not return to its game')
  end
  h.as('Alice') { assert_equal(:back, screen.run) }
  assert(calls.empty?, "#{marker_location}: a retained save action reached its callback")
  assert_equal(1, history_exports.length, "#{marker_location}: tournament text export was blocked")
  assert_equal(initial_events, h.events('Alice'), "#{marker_location}: denied save changed game events")
  assert_equal(initial_stack, h.broker.cores.fetch(h.table['__live_session_id']).entries.length,
    "#{marker_location}: denied save froze or closed the native session")
  assert($spoken_messages.drop(spoken_start).include?('Tournament games cannot be saved or resumed from a saved game.'),
    "#{marker_location}: direct action has no explanation")
  assert(h.transports['Alice'].current_room('Alice'), "#{marker_location}: denied save left the table")
end

# Dynamic menu and F1 help use the same availability source, including when
# only the session (not discovery metadata) has the marker. Export remains.
h, screen = screen_fixture(GameRoomGames::FourInARow.new,
  save_game: ->(*) { raise 'Menu dispatched a forbidden save' },
  save_table_history: ->(*) {})
layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
  user_items: RoomPresentation.user_rows(%w[Alice Bob], owner: 'Alice', players: %w[Alice Bob], active: true))
wait = Struct.new(:action, :replay).new(nil, h.replay('Alice'))
screen.send(:bind_wait_participants, wait, layout, -> {})
menu = FakeMenu.new
layout.form.context(menu, false)
save = menu.options.find { |item| item[0] == 'Save the game and close the table' }
assert(save, 'Ordinary table lost its save menu item')
assert(layout.users.game_room_context_help_tips.any? { |tip| tip.start_with?('Ctrl+S,') },
  'Ordinary context help lost Ctrl+S')
screen.instance_variable_get(:@session)['__tournament_match'] = false
save[3].call
assert(wait.action.nil?, 'Stale menu callback ignored a newly marked session')
menu = FakeMenu.new
layout.form.context(menu, false)
assert(menu.options.none? { |item| item[0] == 'Save the game and close the table' },
  'Session-only marker left saving in the current menu')
tips = layout.users.game_room_context_help_tips
assert(tips.none? { |tip| tip.start_with?('Ctrl+S,') }, 'F1 still offers forbidden Ctrl+S')
assert(tips.any? { |tip| tip.start_with?('Ctrl+Shift+S,') }, 'History export disappeared with saved games')

puts 'PASS tournament direct save action: real GameScreen loop, table/session guards, no freeze/close, retained menu denial, dynamic help and history export'
