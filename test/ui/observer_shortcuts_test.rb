require_relative "../support/native_room_harness"
require_relative "../../lib/participant_menu"
require_relative "../../lib/room_presentation"
require_relative "../../games/makao"
require_relative "../../games/uno"

def snapshot_value(transport, table)
  value = transport.room_snapshot(table, force: true)
  LobbyRepository::TableSnapshot.new(
    table: value.fetch(:table), members: value.fetch(:members), bots: value.fetch(:bots),
    observers: value.fetch(:observers)
  )
end

# A role is an ordered LiveSessions record. It is visible to every member,
# excludes only the selected human from the next game, and survives cleanup.
h = NativeRoomHarness.new(users: %w[Alice Bob Carol], bots: 1)
h.as("Bob") { h.transports.fetch("Bob").set_observer(h.table, true, actor: "Bob") }
h.users.each do |user|
  room = snapshot_value(h.transports.fetch(user), h.table)
  assert(room.observer?("Bob"), "#{user} did not receive Bob's observer role")
  assert(room.game_participants == ["Alice", "Carol", "bot:#{h.table['__id']}:1"],
    "#{user} counted an observer as a player")
end

room = snapshot_value(h.transports.fetch("Alice"), h.table)
assert(GameRoomParticipantMenu.role_actions(room: room, viewer: "Bob") == [:play_next_game],
  "the observer menu did not offer returning to play")
assert(GameRoomParticipantMenu.role_actions(room: room, viewer: "Carol") == [:observe_next_game],
  "the player menu did not offer observer mode")
observer_entry = GameRoomParticipantMenu.entries.find { |entry| entry.action == :observe_next_game }
assert(observer_entry.menu_key == "O" && observer_entry.help_key == "Ctrl+Shift+O",
  "observer mode lost its global shortcut")

session = h.as("Alice") do
  h.repositories.fetch("Alice").start_session(
    table: h.table, game: "test", players: room.game_participants, options: "{}"
  )
end
assert(h.repositories.fetch("Alice").players_for(session) == room.game_participants,
  "an observer leaked into the current game")
h.add_client("Dave")
assert(h.join("Dave"), "a late reader could not join after the role checkpoint")
assert(snapshot_value(h.transports.fetch("Dave"), h.table).observer?("Bob"),
  "stack cleanup lost the observer role")

# The table master may observe while still starting a game for everyone else.
owner_observer = NativeRoomHarness.new(users: %w[Alice Bob])
owner_observer.as("Alice") do
  owner_observer.transports.fetch("Alice").set_observer(owner_observer.table, true, actor: "Alice")
end
owner_room = snapshot_value(owner_observer.transports.fetch("Alice"), owner_observer.table)
assert(owner_room.game_participants == ["Bob"], "the observing master was still counted as a player")
owner_session = owner_observer.as("Alice") do
  owner_observer.repositories.fetch("Alice").start_session(
    table: owner_observer.table, game: "test", players: owner_room.game_participants, options: "{}"
  )
end
assert(owner_observer.repositories.fetch("Alice").players_for(owner_session) == ["Bob"],
  "the LiveSessions owner was incorrectly required to occupy the first seat")
controlled = owner_observer.as("Alice") do
  owner_observer.repositories.fetch("Alice").append_events(
    session: owner_session,
    sequence: 0,
    events: [GameRoomGames::EventCommand.new(action: "tick", value: "automatic")],
    actor: "Bob",
    controller: true
  )
end
assert(controlled.length == 1 && controlled.first["actor"] == "Bob",
  "the observing master could not submit an automatic transition for a game player")

begin
  owner_observer.as("Alice") do
    owner_observer.transports.fetch("Alice").start_game(
      table: owner_observer.table, game: "test", players: %w[Alice Bob],
      options: "{}", actor: "Alice"
    )
  end
  raise "an observer was accepted as a player by the transport"
rescue ArgumentError => error
  raise if !error.message.include?("table roles changed")
end

# Native invitations may advertise a longer lifetime, but Game Room exposes
# and accepts them for at most five minutes.
assert(InvitationRepository::DEFAULT_TTL == 300,
  "the shared invitation lifetime is not five minutes")
invitations = NativeRoomHarness.new(users: %w[Alice Bob])
invitations.as("Alice") do
  invitations.transports.fetch("Alice").invite_user(
    table_id: invitations.table["__id"], user: "Bob",
    metadata: { "purpose" => "game_invitation", "invitation_id" => 7001 }
  )
end
pending = invitations.transports.fetch("Bob").pending_invitations
assert(pending.length == 1 && pending.first["expires_at"] <= Time.now.to_i + 300,
  "the Game Room invitation still exposes the native ten-minute lifetime")
store = invitations.transports.fetch("Bob").instance_variable_get(:@live_store)
stored = store.instance_variable_get(:@pending_invitations).fetch(GameRoomInvitationIdentity.key(pending.first))
assert(stored[:id] == 7001 && stored[:table_id] == invitations.table["__id"] &&
  stored[:invitation].equal?(pending.first.fetch("__native_invitation")),
  "the expiry fixture selected a different invitation")
stored[:created_at] = Time.now.to_i - 301
assert(invitations.transports.fetch("Bob").pending_invitations.empty?,
  "a five-minute-old invitation remained pending")
assert(!stored[:invitation].pending?, "the expired native invitation was not rejected")

# Makao must create its D shortcut before a deal and for observers too.
makao = GameRoomGames::Makao.new
makao_repository = Object.new
makao_repository.define_singleton_method(:players_for) { |_session| %w[Alice Bob] }
makao_replay = makao.replay({ "options" => JSON.generate(makao.default_options) }, [], makao_repository)
%w[Alice Observer].each do |viewer|
  shortcut = makao.custom_game_shortcuts(makao_replay, viewer).find { |entry| entry.key == "d" }
  assert(shortcut && !shortcut.message.to_s.empty?, "Makao created a blank hand shortcut for #{viewer}")
end

# UNO exposes the top card and current colour as two separate announcements.
uno = GameRoomGames::Uno.new
uno_state = uno.send(:initial_state, %w[Alice Bob], uno.default_options)
uno_state[:discard] = ["R50"]
uno_state[:colour] = "R"
uno_replay = GameRoomGames::Replay.new(
  board: nil, players: %w[Alice Bob], current_player: "Alice", winner: nil,
  draw: false, accepted_events: [], history: [], state: uno_state
)
uno_shortcuts = uno.custom_game_shortcuts(uno_replay, "Alice")
card_message = uno_shortcuts.find { |entry| entry.key == "c" && entry.modifiers.empty? }.message
colour_message = uno_shortcuts.find { |entry| entry.key == "v" && entry.modifiers.empty? }.message
assert(!card_message.include?("current colour") && colour_message.include?("Current colour"),
  "UNO still combines the table card and colour under C")

puts "Observer mode, invitation lifetime, Makao and UNO shortcut regressions passed"
