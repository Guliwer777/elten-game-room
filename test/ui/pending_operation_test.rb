require_relative "../support/table_lifecycle_controls_2"

module EltenAPI::Tasks
  class Cancelled < StandardError; end unless const_defined?(:Cancelled)
end

def pending_layout(surface = nil)
  layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new(surface: surface),
    history_items: ['Earlier event'], user_items: %w[Alice Bob], users_header: 'Users', own_table: true)
  layout.session_id = 42
  layout.begin_bindings
  layout.form.define_singleton_method(:key_pressed?) { |_key| false }
  layout.form.define_singleton_method(:main_shortcut_pressed?) { |*| false }
  layout
end

layout = pending_layout(GameSurfaces::GridSpec.new(width: 2, height: 1, header: 'Board', cells: [['a','b']], row_origin: :bottom))
events, clock = [], [10.0]
token = Object.new
token.define_singleton_method(:cancel) { |error| events << error.message }
layout.form.define_singleton_method(:update) { events << :frame }
layout.surface.on_action { events << :move }
layout.chat.on_submit { events << :chat }
layout.back_button.on(:press) { events << :leave }
operation = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 42, token: token, title: 'Sending', clock: -> { clock[0] })
assert(operation.active? && layout.form.game_room_hotkeys_active?, 'Pending operation lost the explicit form owner')
20.times do
  layout.surface.fields.first.trigger(:select, [0, 0])
  layout.chat.trigger(:select)
  layout.back_button.trigger(:press)
end
assert(events.empty?, "Pending table activation escaped its gate: #{events.inspect}")
assert($spoken_messages.count('Please wait...') == 1, 'Holding an action flooded waiting speech')
layout.chat.set_text('Next message')
layout.form.index = layout.form.fields.index(layout.chat)
operation.update
assert(events == [:frame] && layout.chat.text == 'Next message', 'Pending update stopped the full form or draft')
clock[0] = 15.1
operation.update
operation.update
assert($spoken_messages.count('Please wait...') == 2, 'Long operation notice was missing or repeated')
[:announcement, :browse].each do |kind|
  assert(operation.safe_shortcut?(Struct.new(:kind, :action_name).new(kind, nil)), 'Read-only shortcut blocked')
end
assert(!operation.safe_shortcut?(Struct.new(:kind, :action_name).new(:staged_form, 'offer')), 'A staged write was allowed')
assert(!operation.safe_shortcut?(Struct.new(:kind, :action_name).new(:surface, 'new_unclassified_action')), 'Unknown surface command allowed')
layout.form.define_singleton_method(:key_pressed?) { |_key| true }
layout.form.define_singleton_method(:clear_game_room_key) { events << :clear }
operation.update
assert(events.last(2) == ['Task cancelled', :clear], 'Escape did not cancel the native task')
operation.close
operation.close
assert(layout.form.game_room_pending_operation.nil?, 'Pending form owner leaked')
layout.surface.fields.first.trigger(:select, [1, 0])
layout.chat.trigger(:select)
assert(events.last(2) == [:move, :chat], 'Normal actions stayed blocked after cleanup')

operation = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 42, token: token, title: 'Read')
layout.session_id = 43
operation.update
assert(events.last == 'Table view changed', 'A late task updated a different match')
operation.close

previous_guard = -> { false }
layout.surface.action_guard = previous_guard
operation = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 43, token: token, title: 'Read')
operation.close
assert(layout.surface.action_guard.equal?(previous_guard), 'Closing a task erased the preceding surface guard')
operation = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 43, token: token, title: 'Read')
replacement_guard = -> { true }
layout.surface.action_guard = replacement_guard
operation.close
assert(layout.surface.action_guard.equal?(replacement_guard), 'Old cleanup erased a newer surface guard')

layout = pending_layout
chat = layout.chat
chat.set_text('Original')
receipt = GameRoomUI::ChatSubmission.capture(chat, session_id: 42)
assert(receipt.text.frozen?, 'Submitted text is mutable')
chat.set_text('New draft')
assert(!receipt.clear_if_current(chat, session_id: 42) && chat.text == 'New draft', 'New text lost after old confirmation')
chat.set_text('Original')
assert(!receipt.clear_if_current(chat, session_id: 42), 'Identically retyped text is not a new draft')
receipt = GameRoomUI::ChatSubmission.capture(chat, session_id: 42)
chat.trigger(:change)
assert(!receipt.clear_if_current(chat, session_id: 42), 'Native text editing did not advance the draft generation')
receipt = GameRoomUI::ChatSubmission.capture(chat, session_id: 42)
assert(!receipt.clear_if_current(chat, session_id: 43), 'New match draft was cleared')
assert(!receipt.clear_if_current(GameSurfaces::RefreshAwareEditBox.new('Other'), session_id: 42), 'Different editor was cleared')
assert(receipt.clear_if_current(chat, session_id: 42) && chat.text.empty?, 'Unchanged successful draft not cleared')
assert(!receipt.clear_if_current(chat, session_id: 42), 'A confirmation cleared the draft twice')
puts 'PASS pending operation: scoped full form, activation gate, debounced feedback, Escape, stale generation, edit-generation receipts'
