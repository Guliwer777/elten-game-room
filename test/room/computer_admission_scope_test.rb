require_relative '../support/room_interface'
require_relative '../support/native_room_harness'

# Actual waiting-room dispatch and native-contract transport writes. The form
# driver supplies menu activations; it does not stand in for the writer. Extra
# input arrives after the first mutation, before Tasks delivers its result.
module EltenAPI::Tasks
  class << self
    attr_accessor :after_computer_scope_task

    def run(**options)
      result = yield nil, options[:cancellation_token] || CancellationToken.new
      after_computer_scope_task&.call(options, result)
      result
    end
  end
end

module ComputerAdmissionScope
  MODES = %w[owner owner_aba membership account start gates].freeze

  def self.menu_add(layout)
    menu = FakeMenu.new
    layout.form.context(menu, false)
    command = menu.options.find { |entry| entry[2] == 'o' }
    assert(command, 'Expected add menu before the native scope change')
    command.last.call
  end

  def self.run(mode)
    h = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: %w[Alice Bob])
    transport = h.transports.fetch('Alice')
    activity = TableActivityRepository.new(server_tables: {}, transport: transport)
    lobby = LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Alice')),
      transport: transport, server_tables: {}, activity_repository: activity)
    app = EltenGameRoom.allocate
    {lobby: lobby, games: h.repositories.fetch('Alice'), transport: transport,
      table_activity: activity}.each { |name, value| app.instance_variable_set("@#{name}", value) }
    app.define_singleton_method(:start_waiting_table_background) { |*| nil }
    app.define_singleton_method(:announce_server_table_access) {}
    app.define_singleton_method(:leave_table_from_screen) { |_| true }
    app.define_singleton_method(:activate_table_transport) { |_| true }
    tracker = Object.new
    tracker.define_singleton_method(:observe) { |_| [] }
    app.define_singleton_method(:room_membership_tracker) { |_| tracker }
    app.define_singleton_method(:play_game_sounds) { |_| }
    app.define_singleton_method(:play_game_sound) { |_| }
    app.define_singleton_method(:announce_new_table_activity) { |_, after_id:| after_id }
    app.define_singleton_method(:alert) { |message| raise "Unexpected alert: #{message}" }
    app.define_singleton_method(:show_invite_users) { |*| raise 'Invitation escaped the pending gate' }
    app.define_singleton_method(:load_room_state) do |row, title:, **_options|
      run_network_task(title) do
        room = lobby.snapshot_for(row, force: true)
        next nil unless room
        repository = h.repositories.fetch('Alice')
        session = repository.session_for_table(room.table, force: true)
        snapshot = session && repository.snapshot_for(session)
        GameRoomLifecycle::State.new(room: room, game: h.game, game_snapshot: snapshot,
          replay: snapshot && h.game.replay(snapshot.session, snapshot.events, repository),
          activity_entries: activity.entries_for(room.table))
      end
    end
    handoff = false
    app.define_singleton_method(:run_active_table_screen) do |state, row, _prepared|
      assert(mode == 'start', 'Unexpected active handoff')
      layout = instance_variable_get(:@table_layouts).fetch(row.fetch('__id'))
      assert(state.active? && state.session.fetch('__id') == h.session.fetch('__id'), 'Wrong native session entered')
      assert(layout.computer_changes.instance_variable_get(:@commands).empty?,
        'Waiting intentions crossed the active-game boundary')
      handoff = true
      :exit
    end

    injected = false
    EltenAPI::Tasks.after_computer_scope_task = lambda do |options, _result|
      next unless options[:title] == 'Adding computer' && !injected
      injected = true
      layout = app.instance_variable_get(:@table_layouts).fetch(h.table.fetch('__id'))
      assert(options[:ui].equal?(layout.form.game_room_pending_operation) && options[:ui].active?,
        'Injection missed the actual pending gate')
      old_membership = transport.membership_token(h.table)
      3.times { menu_add(layout) }
      layout.chat.set_text('Unsent scope draft')
      case mode
      when 'owner'
        transport.transfer_room_owner(h.table, 'Bob')
      when 'owner_aba'
        transport.transfer_room_owner(h.table, 'Bob')
        h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
        assert(old_membership.equal?(transport.membership_token(h.table)),
          'Owner transfer changed the visit and masked the ownership-ABA boundary')
      when 'membership'
        h.view('Alice').leave
        assert(h.join('Alice'), 'Could not rejoin the same native room')
        h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
        assert(!old_membership.equal?(transport.membership_token(h.table)), 'Rejoin did not create a new attachment')
      when 'account'
        Thread.current[:game_room_test_user] = 'Bob'
      when 'start'
        h.start
      when 'gates'
        menu = FakeMenu.new
        layout.form.context(menu, false)
        invite = menu.options.find { |entry| entry[2] == 'i' }
        assert(invite, 'Invite command missing from an ordinary room')
        invite.last.call
        layout.primary_button.trigger(:press)
        layout.back_button.trigger(:press)
        assert(layout.form.game_room_pending_operation.active?, 'A control bypassed the pending activation gate')
      end
    end

    visits = 0
    Form.driver = lambda do |_form|
      visits += 1
      assert(visits <= 2, 'An extra user activation was needed')
      layout = app.instance_variable_get(:@table_layouts).fetch(h.table.fetch('__id'))
      if visits == 1
        menu_add(layout)
      else
        expected = mode == 'gates' ? 4 : 1
        snapshot = lobby.snapshot_for(h.table, force: true)
        assert(snapshot.bots.length == expected, "Queued intent survived changed #{mode}: #{snapshot.bots.inspect}")
        assert(layout.chat.text == 'Unsent scope draft', 'Scope handling lost the chat draft')
        assert(h.repositories.fetch('Alice').session_for_table(h.table).nil?, 'Adding a computer started a game')
        layout.back_button.trigger(:press)
      end
    end
    h.as('Alice') { app.send(:run_table_screen, h.table) }
    assert(injected, 'The pending injection did not run')
    expected = mode == 'gates' ? 4 : 1
    snapshot = lobby.snapshot_for(h.table, force: true)
    assert(snapshot.bots.length == expected, 'Wrong final roster size')
    additions = activity.entries_for(h.table).count { |entry| entry.kind == 'bot_added' }
    assert(additions == expected, "Unexpected native add history: #{additions}")
    assert(handoff, 'The new native game did not receive a safe screen handoff') if mode == 'start'
    puts "PASS computer admission scope #{mode}: #{additions} acknowledged adds, #{visits} form visits"
  ensure
    Form.driver = nil
    EltenAPI::Tasks.after_computer_scope_task = nil
  end
end

selected = ARGV.empty? ? ComputerAdmissionScope::MODES : ARGV
raise 'Unknown computer admission scope' unless (selected - ComputerAdmissionScope::MODES).empty?
selected.each { |mode| ComputerAdmissionScope.run(mode) }
