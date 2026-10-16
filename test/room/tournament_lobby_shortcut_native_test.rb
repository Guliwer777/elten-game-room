require_relative '../support/tournament_context_native'
require EltenTestHost.file('src/ui/controls/grid_box.rb')
Object.const_set(:GridBox, EltenAPI::Controls.const_get(:GridBox))
require_relative '../../lib/game_surfaces'
require_relative '../../lib/game_history_navigation'
require_relative '../../lib/game_room_screens'

GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
calls = []
program = Object.new
program.define_singleton_method(:show_my_tournaments) { calls << :tournaments }
program.define_singleton_method(:switch_to_invited_table) { calls << :invitation }
shortcut = [17, 16, 84]

driver = TournamentNativeDriver.new
driver.step('Power Games', shortcut)
driver.step('Power Games', shortcut) do |form|
  assert(calls == [:tournaments], 'First native frame lost Ctrl+Shift+T after active controls were cleared')
  items = TournamentNativeContext.items(form)
  action = items.find { |item| item.first == 'My tournaments' }
  assert(action && action.last == 'T', 'Lobby menu does not expose the native Ctrl+Shift+T binding')
end
driver.step('Power Games') do |form|
  assert(calls == [:tournaments], 'Held Ctrl+Shift+T opened tournaments repeatedly')
  form.index = 1 # The lobby history remains part of the lobby.
end
driver.step('Power Games', shortcut)
driver.step('Power Games') { |form| form.show_game_room_help }
driver.step('Keyboard shortcuts', shortcut) do |form|
  assert(form.fields.first.text.include?('Ctrl+Shift+T'), 'Lobby help omits its tournament shortcut')
  assert(!TournamentNativeContext.items(form).any? { |item| item.first == 'My tournaments' },
    'Help dialog inherited the lobby tournament action')
end
driver.step('Keyboard shortcuts', [27])
driver.step('Power Games', [17, 74]) do
  assert(calls == [:tournaments, :tournaments], 'Help activated tournaments or lobby history lost its shortcut')
end
driver.step('Power Games', [27])
result = GameRoomScreens::MainMenu.new(options: ['Create a new table'], history_items: ['Earlier activity'], program: program).wait
driver.finish
assert(result.action == :exit && calls == [:tournaments, :tournaments, :invitation], 'Lobby navigation or Ctrl+J regressed')

%w[Game Settings Tournaments].each do |header|
  driver = TournamentNativeDriver.new
  field = ListBox.new(['Item'], header: header, quiet: true)
  close = Button.new('Close')
  form = GameRoomUI::Form.new([field, close], program: program, quiet: true)
  form.cancel_button = close
  form.hide(close)
  close.on(:press) { form.resume }
  driver.step(header, shortcut) do |current|
    assert(!TournamentNativeContext.items(current).any? { |item| item.first == 'My tournaments' },
      "#{header} advertises a lobby-only action")
  end
  driver.step(header) { |current| current.show_game_room_help }
  driver.step('Keyboard shortcuts', shortcut) do |current|
    assert(!current.fields.first.text.include?('Ctrl+Shift+T'), "#{header} help advertises a lobby-only shortcut")
  end
  driver.step('Keyboard shortcuts', [27])
  driver.step(header, [27])
  form.wait
  driver.finish
end
assert(calls == [:tournaments, :tournaments, :invitation], 'A non-lobby form activated tournaments')
puts 'PASS native lobby shortcut: real MainMenu, cleared frame controls, held keys, history, help scope and unchanged Ctrl+J'
