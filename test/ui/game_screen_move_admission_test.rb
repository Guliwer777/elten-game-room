require_relative '../support/background_help_game_screen'

module EltenAPI::Tasks
  class << self
    attr_accessor :move_probe
    alias run_without_move_probe run
    def run(**options, &block)
      move_probe&.call(options)
      run_without_move_probe(**options, &block)
    end
  end
end

[:chat, :read, :stale].each do |scenario|
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  activity = TableActivityRepository.new(server_tables: {}, transport: h.transports['Alice'])
  other = TableActivityRepository.new(server_tables: {}, transport: h.transports['Bob'])
  screen.instance_variable_set(:@activity_repository, activity)
  screen.instance_variable_set(:@send_chat, ->(table, text, _members, **options) {
    activity.append(table: table, kind: 'chat', message: text, **options)
  })
  captured = false
  EltenAPI::Tasks.move_probe = lambda do |options|
    pending = options[:ui]
    next unless pending.is_a?(GameRoomUI::PendingOperation) && !captured
    expected = scenario == :read ? 'Updating table' : 'Sending chat message'
    next unless options[:title] == expected
    layout = screen.instance_variable_get(:@layout)
    captured = true
    layout.form.index = layout.form.fields.index(layout.surface.fields.first)
    10.times { layout.surface.fields.first.trigger(:select, [0, 0]) }
    if scenario == :stale
      # A complete turn passes while the queued gesture still describes the
      # old board. Even though it is Alice's turn again, it must not be rebased.
      h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 1, 'y' => 0})
      h.submit('Bob', {'kind' => 'grid', 'action' => 'select', 'x' => 2, 'y' => 0})
    end
  end
  started = false
  Form.driver = lambda do |form|
    layout = screen.instance_variable_get(:@layout)
    if !started
      started = true
      if scenario == :read
        h.as('Bob') { other.append(table: h.table, kind: 'chat', message: 'Read trigger') }
      else
        layout.chat.set_text('An independent message')
        layout.chat.trigger(:select)
      end
    elsif captured && screen.instance_variable_get(:@pending_move_intent) == nil
      expected = scenario == :stale ? 2 : 1
      assert(h.events('Alice').length == expected, "#{scenario}: lost, duplicated or rebased the queued move")
      assert(screen.instance_variable_get(:@selected_surface_action) == nil, 'A captured selection leaked into another wait')
      layout.back_button.trigger(:press)
    end
  end
  h.as('Alice') { assert(screen.run == :back, "#{scenario}: exit failed") }
  assert(captured, "#{scenario}: did not exercise the pending operation")
end
puts 'PASS GameScreen move admission during chat/read: one immutable gesture, duplicate suppression, stale full-turn rejection'
