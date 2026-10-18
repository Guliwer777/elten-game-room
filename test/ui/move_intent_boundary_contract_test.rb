require_relative '../support/background_help_game_screen'

module IndependentMoveIntentTaskProbe
  attr_accessor :move_intent_contract_probe
  def run(**options, &block)
    move_intent_contract_probe&.call(options)
    super
  end
end
EltenAPI::Tasks.singleton_class.prepend(IndependentMoveIntentTaskProbe)

[:chat, :table_read].each do |operation|
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  activities = TableActivityRepository.new(server_tables: Object.new, transport: h.transports.fetch('Alice'))
  screen.instance_variable_set(:@send_chat, lambda do |table, text, _members, **options|
    activities.append(table: table, kind: 'chat', message: text, actor: 'Alice', **options)
  end)
  captured = false
  title = operation == :chat ? 'Sending chat message' : 'Updating table'
  EltenAPI::Tasks.move_intent_contract_probe = lambda do |options|
    next unless options[:title] == title && !captured
    captured = true
    layout = screen.instance_variable_get(:@layout)
    assert(options[:ui].is_a?(GameRoomUI::PendingOperation), 'Independent operation did not retain the game form')
    # This is the displayed native-adapter board event, not a direct runner
    # call. Several later gestures must not overwrite or duplicate the first.
    layout.form.index = layout.form.fields.index(layout.surface.fields.first)
    layout.surface.fields.first.trigger(:select, [0, 0])
    4.times { layout.surface.fields.first.trigger(:select, [0, 1]) }
    layout.chat.set_text('A later unsubmitted draft') if operation == :chat
  end
  stage, frames = :start, 0
  Form.driver = lambda do |_form|
    layout = screen.instance_variable_get(:@layout)
    case stage
    when :start
      stage = :waiting
      if operation == :chat
        layout.form.index = layout.form.fields.index(layout.chat)
        layout.chat.set_text('Before the independent move')
        layout.chat.trigger(:select)
      else
        h.transports.fetch('Alice').update_room(h.table, {'name' => 'Updated by native room metadata'}, actor: 'Alice')
      end
    when :waiting
      frames += 1
      events = h.events('Alice')
      if !captured || events.empty?
        raise "First board activation during #{operation} was discarded; another Enter is required" if frames > 300
        next
      end
      assert(events.length == 1 && events.first['action'] == 'drop' && events.first['value'] == '1',
        "#{operation}: repeated activation overwrote or duplicated the captured move")
      assert(h.replay('Bob').current_player == 'Bob', "#{operation}: the recipient did not receive the real legal move")
      assert(screen.instance_variable_get(:@pending_move_intent).nil?, "#{operation}: accepted intent stayed queued")
      if operation == :chat
        assert(layout.chat.text == 'A later unsubmitted draft', 'Move/chat acknowledgement erased a newer draft')
        rows = activities.entries_for(h.table).select { |entry| entry.kind == 'chat' }
        assert(rows.map(&:message) == ['Before the independent move'], 'Move admission lost or duplicated chat')
      end
      stage = :done
      layout.back_button.trigger(:press)
    end
  end
  h.as('Alice') { assert(screen.run == :back, "#{operation}: normal exit failed") }
  assert(stage == :done, "#{operation}: incomplete fixture")
end
EltenAPI::Tasks.move_intent_contract_probe = nil

puts 'PASS independent pending move: native board activation survives chat and table read, first gesture stays immutable, repeated gestures do not queue more moves, chat and newer draft survive'
