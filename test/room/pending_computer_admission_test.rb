require_relative '../support/room_interface'
require_relative '../support/native_room_harness'

# Native-session mutation and the actual waiting-room menu/dispatch. Only the
# task scheduler is controlled: extra key presses arrive before the first
# membership write completes, just as they do on a slower real connection.
module EltenAPI::Tasks
  class << self
    attr_accessor :computer_probe
    def run(**options)
      computer_probe&.call(options)
      yield nil, options[:cancellation_token] || CancellationToken.new
    end
  end
end

def computer_menu(layout, action, participant = nil)
  menu = FakeMenu.new
  if action == :add_bot
    layout.form.context(menu, false)
    option = menu.options.find { |entry| entry[2] == 'o' }
  else
    layout.users.index = layout.users.options.index { |label| label.include?(GameRoomParticipants.display_name(participant)) }
    layout.users.context(menu, false)
    option = menu.options.find { |entry| entry[2] == :del }
  end
  raise "Missing computer command #{action}" unless option
  option.last.call
end

h = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: ['Alice'])
activity = TableActivityRepository.new(server_tables: {}, transport: h.transports['Alice'])
lobby = LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Alice')),
  transport: h.transports['Alice'], server_tables: {}, activity_repository: activity)
app = EltenGameRoom.allocate
app.instance_variable_set(:@lobby, lobby)
app.instance_variable_set(:@games, h.repositories['Alice'])
app.instance_variable_set(:@transport, h.transports['Alice'])
app.instance_variable_set(:@table_activity, activity)
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
app.define_singleton_method(:alert) { |text| raise "Unexpected alert: #{text}" }
app.define_singleton_method(:load_room_state) do |row, title:, **_options|
  run_network_task(title) do
    GameRoomLifecycle::State.new(room: lobby.snapshot_for(row), game: h.game,
      game_snapshot: nil, replay: nil, activity_entries: activity.entries_for(row))
  end
end

pressed = removed = false
original_bots = []
EltenAPI::Tasks.computer_probe = lambda do |options|
  next unless options[:ui].is_a?(GameRoomUI::PendingOperation)
  layout = app.instance_variable_get(:@table_layouts).fetch(h.table['__id'])
  if options[:title] == 'Adding computer' && !pressed
    pressed = true
    7.times { computer_menu(layout, :add_bot) }
    layout.chat.set_text('Draft survives the batch')
  elsif options[:title] == 'Removing computer' && !removed
    removed = true
    4.times { computer_menu(layout, :remove_bot, original_bots[1]) }
    computer_menu(layout, :remove_bot, original_bots[5])
  end
end
visits = 0
Form.driver = lambda do |_form|
  layout = app.instance_variable_get(:@table_layouts).fetch(h.table['__id'])
  visits += 1
  if visits == 1
    computer_menu(layout, :add_bot)
  elsif visits == 2
    snapshot = lobby.snapshot_for(h.table, force: true)
    assert(pressed, 'The fixture did not deliver keys during the write')
    assert(snapshot.bots.length == 7, "Rapid add commands were lost or capacity exceeded: #{snapshot.bots.length} bots")
    assert(snapshot.bots.uniq.length == 7, 'A repeated addition reused a computer identity')
    assert(activity.entries_for(h.table).count { |entry| entry.kind == 'bot_added' } == 7,
      'Computer history is missing or duplicated')
    assert(layout.chat.text == 'Draft survives the batch', 'Computer batch erased the chat draft')
    assert(!$spoken_messages.include?('Please wait...'), 'Accepted computer keys still announce a blocked action')
    original_bots = snapshot.bots.dup
    computer_menu(layout, :remove_bot, original_bots[1])
  else
    snapshot = lobby.snapshot_for(h.table, force: true)
    # Ordinary rooms compact the numbered bot slots after removing one. Compare
    # the actual names, not the old slot numbers of surviving computers.
    names = ->(bots) { bots.map { |bot| GameRoomParticipants.bot_name_token(bot) } }
    assert(removed && names.call(snapshot.bots) == names.call(original_bots - [original_bots[5], original_bots[1]]),
      'Queued Delete removed a different row, or repeated the same mutation')
    events = activity.entries_for(h.table).select { |entry| entry.kind == 'bot_removed' }
    assert(names.call(events.map(&:subject)) == names.call([original_bots[1], original_bots[5]]), 'Removal identity/history changed')
    layout.back_button.trigger(:press)
  end
end
begin
  h.as('Alice') { app.send(:run_table_screen, h.table) }
  assert(visits == 3, 'Computer changes required more user input')
ensure
  Form.driver = nil
  EltenAPI::Tasks.computer_probe = nil
end

context = {table_id: 1, session_id: 2, actor: 'Alice', owner: 'Alice', membership: Object.new, ownership: Object.new}
buffer = GameRoomUI::ComputerChangeBuffer.new
8.times { assert(buffer.enqueue(:add_bot, **context), 'A bounded computer intention was rejected') }
assert(!buffer.enqueue(:add_bot, **context), 'The command buffer is unbounded')
assert(!buffer.enqueue(:start_game, **context), 'A game start entered the roster buffer')
8.times { assert(buffer.take(**context) == [:add_bot, nil], 'A buffered command was dropped') }
assert(buffer.take(**context).nil?, 'An extra command was invented')
[:table_id, :session_id, :actor, :owner, :membership, :ownership].each do |key|
  assert(buffer.enqueue(:add_bot, **context), 'Could not queue the scope test')
  changed = context.merge(key => ([:membership, :ownership].include?(key) ? Object.new : key == :actor || key == :owner ? 'Bob' : 999))
  assert(buffer.take(**changed).nil? && buffer.take(**context).nil?, "#{key} change carried a command into another scope")
end
buffer.enqueue(:add_bot, **context)
assert(buffer.take(**context.merge(actor: 'alice', owner: 'ALICE')) == [:add_bot, nil], 'Login case changed command ownership')
named = original_bots.take(2)
named.each { |bot| buffer.enqueue(:remove_bot, bot, **context) }
buffer.enqueue(:add_bot, **context)
shifted = GameRoomParticipants.bot_id(1, 1, name_token: GameRoomParticipants.bot_name_token(named.last))
buffer.removed(named.first, before: named, after: [shifted])
assert(buffer.take(**context) == [:remove_bot, shifted], 'Confirmed slot compaction lost the next named target')
assert(buffer.take(**context) == [:add_bot, nil] && buffer.take(**context).nil?, 'Removed identity survived or another command disappeared')
buffer.enqueue(:remove_bot, named.first, **context)
buffer.removed(named.first, before: named, after: [shifted])
assert(buffer.take(**context).nil?, 'A newly added bot could inherit an already removed name intention')
buffer.enqueue(:add_bot, **context)
buffer.removed(named.first, before: named, after: named)
assert(buffer.take(**context).nil?, 'An unexplained roster change retained queued mutations')
puts 'PASS rapid computers: native add/remove menus, serial writes, bounded/full room, stable removal identities, scope changes, history and draft'
