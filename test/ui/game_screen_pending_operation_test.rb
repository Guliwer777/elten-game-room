require_relative "../support/background_help_game_screen"

module EltenAPI::Tasks
  class << self
    attr_accessor :pending_probe
    alias run_without_pending_probe run
    def run(**options, &block)
      pending_probe&.call(options)
      run_without_pending_probe(**options, &block)
    end
  end
end

$game_room_test_user = 'Alice'
h, screen = screen_fixture(GameRoomGames::FourInARow.new)
sent = []
entry_class = Struct.new(:id, :kind, :actor, :message)
screen.instance_variable_set(:@send_chat, ->(_table, text, _members, **_options) { sent << text; entry_class.new(sent.length, 'chat', 'Alice', text) })
stage = :move
checked_move = checked_chat = false
EltenAPI::Tasks.pending_probe = lambda do |options|
  pending = options[:ui]
  next unless pending.is_a?(GameRoomUI::PendingOperation)
  layout = screen.instance_variable_get(:@layout)
  assert(pending.active?, 'Network boundary received a stale form')
  if options[:title] == 'Sending action' && !checked_move
    checked_move = true
    layout.form.index = layout.form.fields.index(layout.chat)
    layout.chat.set_text('Written during move')
    30.times do
      layout.surface.fields.first.trigger(:select, [1, 0])
      layout.chat.trigger(:select)
      layout.back_button.trigger(:press)
      pending.update
    end
    assert(layout.chat.text == 'Written during move', 'UI work lost pending-move draft')
  elsif options[:title] == 'Sending chat message' && !checked_chat
    checked_chat = true
    layout.chat.set_text('Second message')
    30.times { layout.chat.trigger(:select); pending.update }
    layout.chat.set_text('Next draft')
  end
end
Form.driver = lambda do |form|
  layout = screen.instance_variable_get(:@layout)
  case stage
  when :move
    stage = :finish
    layout.surface.fields.first.trigger(:select, [0, 0])
  when :finish
    assert(checked_move, 'Move did not retain the table form')
    assert(h.events('Alice').length == 1, 'Pending input submitted a second move')
    assert(checked_chat && sent == ['Written during move', 'Second message'], 'First Enter during an unrelated operation was lost, duplicated or read mutable text')
    assert(layout.chat.text == 'Next draft' && layout.focus_location == [:chat, 0], 'Acknowledgement erased the next draft')
    assert(layout.form.game_room_pending_operation.nil?, 'Pending flag survived the task')
    layout.back_button.trigger(:press)
  end
end
h.as('Alice') { assert(screen.run == :back, 'Normal exit changed') }
assert(checked_move && checked_chat, 'Scenario did not reach both operations')
puts 'PASS real GameScreen loop: chat admitted during move/send, one game commit, immutable bounded chat, newer draft and focus retained, cleanup'
