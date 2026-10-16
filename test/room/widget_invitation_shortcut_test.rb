require_relative "../support/widget_presets"

active, first, modifiers = true, true, [:control]
accepted, created, alerts, consumed, tournaments = [], [], [], 0, 0
key = 'j'
widget = GameRoomWidget::TableList.new(
  loader: -> { raise 'Ctrl+J unnecessarily refreshed discovery' },
  opener: ->(*) { raise 'Ctrl+J opened the selected public table' },
  labeler: ->(*) {}, id_for: ->(*) {}, active: -> { active },
  worker: WidgetManualWorker.new, clock: -> { 0 },
  creator: ->(slot) { created << slot },
  tournaments: -> { tournaments += 1; widget.send(:open_my_tournaments) },
  invitations: lambda {
    accepted << :accepted
    widget.update
    widget.send(:accept_invitation)
    widget.send(:create_table, nil)
  })
widget.extend(EltenAPI::UI)
widget.define_singleton_method(:keyboard_code) { |value| [value.to_s.upcase.ord, false] }
widget.define_singleton_method(:raw_key_first_pressed?) { |code| first && code == key.upcase.ord }
widget.define_singleton_method(:raw_key_pressed?) { |code| code == key.upcase.ord }
widget.define_singleton_method(:keyboard_modifier_held_when_pressed?) { |_, modifier| modifiers.include?(modifier) }
widget.define_singleton_method(:key_pressed?) { |_| false }
widget.define_singleton_method(:getkeychar) { consumed += 1; '' }
widget.define_singleton_method(:alert) { |text| alerts << text }
widget.instance_variable_set(:@refresh_at, Float::INFINITY)
widget.update
assert(accepted == [:accepted] && created.empty? && consumed == 1, 'Ctrl+J repeats, creates a table or leaks into character search')
first = false
10.times { widget.update }
assert(accepted.length == 1, 'Held Ctrl+J repeatedly accepts invitations')
first = true
[[], [:control, :shift], [:control, :option], [:shift], [:option]].each do |held|
  modifiers = held
  widget.update
end
assert(accepted.length == 1, 'Plain J or extra modifiers activate invitation acceptance')
modifiers = [:control]
active = false
widget.update
widget.send(:accept_invitation)
assert(accepted.length == 1, 'Off-widget acceptance is active')
active = true
global = FakeMenu.new
widget.context(global, true)
assert(global.options.empty?, 'Widget invitation action leaked to the global menu')
local = FakeMenu.new
widget.context(local, false)
local.options.find { |item| item.first == 'Accept invitation' }.last.call
assert(accepted.length == 2, 'Context action does not use the same callback')
assert(widget.get_tips.count { |tip| tip.start_with?('Ctrl+J') } == 1, 'Ctrl+J help missing or duplicated')
key, modifiers = 't', [:control, :shift]
widget.update
assert(tournaments == 1, 'Ctrl+Shift+T did not open tournaments exactly once')
first = false
widget.update
assert(tournaments == 1, 'Held Ctrl+Shift+T reopened tournaments')
first = true
active = false
widget.update
assert(tournaments == 1, 'Off-widget Ctrl+Shift+T is active')
active = true
tournament_action = local.options.find { |item| item.first == 'My tournaments' }
assert(tournament_action[2] == 'T', 'Widget menu does not expose native Ctrl+Shift+T')
tournament_action.last.call
assert(tournaments == 2, 'Tournament menu callback differs from the shortcut')
key, modifiers = 'j', [:control]
widget.instance_variable_set(:@invitations, -> { raise IOError, 'simulated invitation failure' })
widget.update
assert(alerts.last == 'The operation could not be completed. Please try again.', 'Failure was silent or called a creation error')
widget.instance_variable_set(:@invitations, -> { accepted << :recovered })
widget.update
assert(accepted.last == :recovered, 'An error left the widget permanently guarded')

# Use the real app switch and its existing common invitation picker. Do not
# invent a second network, join or notification-cleanup implementation.
app = EltenGameRoom.allocate
calls = []
row = {'id' => 12}
app.define_singleton_method(:prepare_widget_program) { calls << :prepare }
app.define_singleton_method(:show_pending_invitations) { calls << :ordinary_picker; row }
app.define_singleton_method(:run_program_interface) { |table| calls << [:interface, table] }
app.send(:accept_invitation_from_widget)
assert(calls == [:prepare, :ordinary_picker, [:interface, row]], 'Widget bypasses the normal Ctrl+J route')
row = nil
calls.clear
app.send(:accept_invitation_from_widget)
assert(calls == [:prepare, :ordinary_picker], 'Empty/cancelled/rejected invitation unnecessarily opens the app')

# Exercise the actual factory wiring, not only a hand-built control.
app.define_singleton_method(:initialize_services) {}
app.define_singleton_method(:widget_active?) { true }
app.define_singleton_method(:launch_game_room_entry) { |*request| calls << request }
built = app.send(:build_widget_control)
built.send(:accept_invitation)
assert(calls.last == [:accept_invitation_from_widget], 'Real widget factory did not connect Ctrl+J to the shared scene launch')
built.send(:open_my_tournaments)
assert(calls.last == [:open_tournaments_from_widget], 'Tournament quick access bypasses the single-instance scene launch')
built.send(:create_table, nil)
assert(calls.last == [:create_table_from_widget, nil], 'Ctrl+N bypasses the shared scene launch')
built.send(:create_table, 29)
assert(calls.last == [:create_table_from_widget, 29], 'A preset bypasses the shared scene launch or loses its slot')
snapshot = Object.new
built.instance_variable_get(:@opener).call(snapshot)
assert(calls.last == [:open_widget_table, snapshot], 'Opening a selected table bypasses the shared scene launch')
built.close
widget.close
puts 'PASS widget invitations: native Ctrl+J scope, repeats, reentry, menu/help, errors and existing application route'
