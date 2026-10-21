require_relative "../support/table_lifecycle_controls_2"

broker = NativeLiveSessionsBroker.new
$game_room_test_user = "Alice"
app = LifecycleApp.new(broker)
table = app.lobby.create_table(name: "Lifecycle", game: "four_in_a_row", owner: "Alice", game_options: "{}").table
other = GameRoomTransport.new(ProgramDouble.new(broker.endpoint("Bob")))
other.join_room(table, "Bob")
core = broker.cores[table["__live_session_id"]]
initial_members = core.participants.dup
app.form_answer = nil
before = core.entries.length
assert(!app.send(:change_table_game_options, table) && core.entries.length == before, "Cancel must not write anything")
app.form_answer = { "bot_delay" => 2 }
assert(app.send(:change_table_game_options, table), "settings before start")
assert(app.form_initial[1]["bot_delay"] == 1 && app.form_initial[2] == "Save changes", "prefill and save label")
assert(core.entries.length == before + 1, "settings and history must use one record")
room = app.lobby.snapshot_for(table)
assert(JSON.parse(room.table["game_options"])["bot_delay"] == 2, "new settings not projected")
session = app.games.start_session(table: room.table, game: "four_in_a_row", players: %w[Alice Bob], options: room.table["game_options"])
game = GameRoomGames::FourInARow.new
status, event = game.action_for({ "kind" => "grid", "action" => "select", "x" => 0 }, game.replay(session, [], app.games), "Alice")
# Use a legal action from the engine; the terminal boundary is independent of
# particular phases such as auctions, quizzes or a pending colour selection.
assert(status == :ok, "fixture move must be legal")
app.games.append_events(session: session, events: event.events, sequence: 1, actor: "Alice")
snapshot = app.games.snapshot_for(session)
count = snapshot.events.length
assert(!app.send(:change_table_game_options, table), "cannot edit an active game")
$game_room_test_user = "Bob"
assert(!other.abort_game(session), "a guest cannot end the match")
$game_room_test_user = "Alice"
app.confirmed = false
assert(!app.send(:abort_current_game, table, session), "confirmation cancellation")
app.confirmed = true
broker.endpoint('Alice').sessions.first.fail_next_push = :after
assert(app.send(:abort_current_game, table, session), "master abort")
assert(app.transport.abort_game(session), "idempotent abort")
assert(core.participants == initial_members && !core.closed, "room or members changed")
state = app.send(:load_room_state, table, title: "test", force: true)
assert(state.waiting? && !state.finished? && state.session["__aborted"], "terminal game did not become waiting")
assert(state.replay.winner == nil && !state.replay.draw, "abort invented a result")
assert(state.game_snapshot.events.length == count, "abort changed old game events")
history = app.instance_variable_get(:@table_activity).entries_for(table)
assert(history.count { |item| item.kind == "game_aborted" } == 1, "duplicate abort history")
assert(history.count { |item| item.kind == "options_changed" } == 1, "missing settings history")
begin
  app.transport.freeze_game(session, frozen: false)
  raise "abort was reversibly unfrozen"
rescue GameRoomNetworkErrors::GamePaused
end
# A stale client can still write a packet. It is ignored after the boundary,
# even if followed by a stale save-unfreeze or stale room status.
old_packet = { "version" => GameRoomLiveSessionStore::PROTOCOL, "kind" => "game_action", "actor" => "Bob",
  "data" => { "session_id" => session["__id"], "sequence" => 99,
    "events" => [{ "action" => "play", "value" => "2", "move_id" => SecureRandom.uuid }] } }
broker.endpoint("Bob").sessions.first.stack_push(old_packet, message_id: SecureRandom.uuid)
app.transport.update_room(table, { "status" => "playing" }, actor: "Alice")
fresh = GameRoomTransport.new(ProgramDouble.new(broker.endpoint("Alice", fresh: true)))
fresh.join_room(table, "Alice")
assert(fresh.game_session(session["__id"], table: table)["__aborted"], "reconnect resurrected the game")
assert(fresh.game_events(session, force: true).length == count, "late action entered replay")
assert(app.lobby.snapshot_for(table).table["status"] == "waiting", "stale status resurrected table")
app.form_answer = { "bot_delay" => 3 }
assert(app.send(:change_table_game_options, table), "cannot edit after abort")
room = app.lobby.snapshot_for(table)
next_session = app.games.start_session(table: room.table, game: game.id, players: %w[Alice Bob], options: room.table["game_options"], expected_previous_session_id: session["__id"])
assert(next_session["__id"] != session["__id"] && !next_session["__aborted"], "fresh start retained old terminal state")
assert(JSON.parse(next_session["options"])["bot_delay"] == 3 && app.games.snapshot_for(next_session).events.empty?, "new game inherited old options or events")
assert(!app.send(:abort_current_game, table, session), "stale confirmation ended a different game")

assert(GameRoomParticipantMenu.lifecycle_actions(active: true, viewer: "Alice", owner: "Alice") == [:abort_game], "active owner menu")
assert(GameRoomParticipantMenu.lifecycle_actions(active: false, viewer: "Alice", owner: "Alice") == [:edit_options], "waiting owner menu")
assert(GameRoomParticipantMenu.lifecycle_actions(active: false, viewer: "Alice", owner: "Alice", restoring: true).empty?, "archive settings must be locked")
assert(GameRoomParticipantMenu.lifecycle_actions(active: true, viewer: "Alice", owner: "Alice", compatible: false).empty?, "legacy room controls must remain hidden")
assert(GameRoomParticipantMenu.lifecycle_actions(active: true, viewer: "Bob", owner: "Alice").empty?, "guest lifecycle menu")

# Replaying overlapping changes must retain the first accepted settings even
# when both senders checked the same old state before transmitting.
assert(app.send(:abort_current_game, table, next_session), 'second game abort')
old_options = app.lobby.snapshot_for(table).table['game_options']
old_change_count = app.instance_variable_get(:@table_activity).entries_for(table).count { |item| item.kind == 'options_changed' }
assert(app.transport.change_game_options(table: table, options: '{"bot_delay":4}', expected_options: old_options, expected_session_id: next_session['__id']), 'first of concurrent options changes was rejected')
conflict = { 'version' => 2, 'kind' => 'room_state', 'actor' => 'Alice', 'data' => {
  'game_options' => '{"bot_delay":5}', 'options_changed' => true,
  'expected_options' => old_options, 'expected_session_id' => next_session['__id'], 'updated_at' => Time.now.to_i } }
broker.endpoint('Alice').sessions.first.stack_push(conflict, message_id: SecureRandom.uuid)
assert(JSON.parse(app.lobby.snapshot_for(table).table['game_options'])['bot_delay'] == 4, 'concurrent option dialog overwrote accepted values')
history = app.instance_variable_get(:@table_activity).entries_for(table)
assert(history.count { |item| item.kind == 'options_changed' } == old_change_count + 1, 'ignored options conflict created a history entry')

layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new, history_items: [], user_items: [], users_header: 'Users', phase: :waiting, own_table: true)
GameRoomParticipantMenu.bind(layout, available: -> { [:edit_options] }) { }
menu = LifecycleMenu.new
layout.form.context(menu)
assert(menu.items.find { |item| item[0] == 'Change settings for the next game' }[1] == 'x', 'Ctrl+X outside text')
layout.form.index = layout.form.fields.index(layout.chat)
menu = LifecycleMenu.new
layout.form.context(menu)
assert(menu.items.find { |item| item[0] == 'Change settings for the next game' }[1] == '', 'Ctrl+X must remain Cut in chat')

# Settings can be prepared before the remaining players arrive.
solo_broker = NativeLiveSessionsBroker.new
solo = LifecycleApp.new(solo_broker)
taboo = GameRoomGames::Taboo.new
solo_table = solo.lobby.create_table(name: 'Waiting for a team', game: taboo.id, owner: 'Alice', game_options: JSON.generate(taboo.normalize_options({}))).table
solo.form_answer = taboo.normalize_options('turn_seconds' => 90)
assert(solo.send(:change_table_game_options, solo_table), 'a lone master must be able to configure Taboo before others join')

puts "Table lifecycle controls passed: atomic settings/history, owner checks, cancellation, terminal replay, late moves, reconnect, new game."
