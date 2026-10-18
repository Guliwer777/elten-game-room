require_relative '../support/room_interface'
require_relative '../support/native_room_harness'

module EltenAPI::Tasks
  class << self
    attr_accessor :computer_probe
    def run(**options)
      computer_probe&.call(options)
      yield nil, options[:cancellation_token] || CancellationToken.new
    end
  end
end

h = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: %w[Alice Bob],
  options: {'score_limit' => 50, 'entry_minimum' => 0, 'turn_minimum' => 0})
h.start
context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
  now: 1_000, random_source: GameRoomRandom::SeededSource.new(417))
300.times do
  replay = h.replay('Alice')
  break if replay.finished?
  choices = h.game.legal_actions(replay, replay.current_player)
  action = choices.find { |item| item['action'] == 'bank' } || choices.first
  h.submit(replay.current_player, action, context: context)
end
assert(h.replay('Alice').finished?, 'The native Farkle fixture did not finish')
activity = TableActivityRepository.new(server_tables: {}, transport: h.transports['Alice'])
program = ProgramDouble.new(h.broker.endpoint('Alice'))
lobby = LobbyRepository.new(program, transport: h.transports['Alice'], server_tables: {}, activity_repository: activity)
app = EltenGameRoom.allocate
app.instance_variable_set(:@lobby, lobby)
app.define_singleton_method(:announce_server_table_access) {}
app.define_singleton_method(:load_room_state) do |row, title:, **_options|
  run_network_task(title) do
    snapshot = h.repositories['Alice'].snapshot_for(h.session)
    GameRoomLifecycle::State.new(room: lobby.snapshot_for(row), game: h.game,
      game_snapshot: snapshot, replay: h.game.replay(snapshot.session, snapshot.events, h.repositories['Alice']))
  end
end
sync = GameRoomSync::Controller.new(transport: h.transports['Alice'], table_id: h.table['__id'], session_id: h.session['__id'])
screen = GameScreen.new(program: program, repository: h.repositories['Alice'], game: h.game,
  session: h.session, table: h.table, table_owner: 'Alice', synchronizer: sync,
  room_snapshot_provider: -> { lobby.snapshot_for(h.table) },
  game_services: {transport: h.transports['Alice']},
  manage_computer: ->(*args) { app.send(:change_room_computer, *args) })
screen.define_singleton_method(:alert) { |text| raise "Unexpected alert: #{text}" }
add = lambda do
  menu = FakeMenu.new
  screen.instance_variable_get(:@layout).form.context(menu, false)
  menu.options.find { |entry| entry[2] == 'o' }.last.call
end
pressed = false
EltenAPI::Tasks.computer_probe = lambda do |options|
  next unless options[:title] == 'Adding computer' && !pressed
  assert(options[:ui].is_a?(GameRoomUI::PendingOperation), 'The roster write lost its displayed game gate')
  pressed = true
  7.times { add.call }
end
visits = 0
Form.driver = lambda do |_form|
  visits += 1
  layout = screen.instance_variable_get(:@layout)
  if visits == 1
    assert(layout.phase == :finished, 'The fixture is not a finished-game screen')
    app.instance_variable_set(:@table_network_view, {layout: layout, table_id: h.table['__id'], synchronizer: sync})
    add.call
  else
    assert(pressed && lobby.snapshot_for(h.table, force: true).bots.length == 6,
      'Finished-game roster commands were dropped or exceeded capacity')
    assert(h.replay('Bob').finished?, 'Roster commands restarted or changed the finished game')
    layout.back_button.trigger(:press)
  end
end
begin
  h.as('Alice') { assert(screen.run == :back, 'Finished game did not exit normally') }
  assert(visits == 2, 'Finished screen required repeated commands')
ensure
  Form.driver = nil
  EltenAPI::Tasks.computer_probe = nil
end
puts 'PASS finished Farkle: full native match, normal GameScreen, rapid roster menu commands, unchanged result and full-table bound'
