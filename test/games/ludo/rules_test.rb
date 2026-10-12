require_relative "../../support/new_board_games"

players = ["Alice", "Bob"]
repository = NewGamesRepository.new(players)
session = { "options" => "{}" }

ludo_players = ["Alice", "Bob", "Carol", "Dave"]
ludo_repository = NewGamesRepository.new(ludo_players)
ludo = GameRoomGames::Ludo.new
ludo_replay = ludo.replay(session, [], ludo_repository)
assert(ludo.minimum_players == 2 && ludo.maximum_players == 4, "Ludo has invalid player limits")
assert(ludo_replay.state[:pawns].all? { |pawns| pawns == [-1, -1, -1, -1] }, "Ludo pawns do not start in their bases")
ludo_shortcuts = ludo.game_shortcuts(ludo_replay, "Alice")
own_pawns_shortcut = ludo_shortcuts.find { |shortcut| shortcut.key == "p" && shortcut.modifiers.empty? }
opponent_pawns_shortcut = ludo_shortcuts.find { |shortcut| shortcut.key == "p" && shortcut.modifiers == [:shift] }
own_pawn_list = ludo_shortcuts.find { |shortcut| shortcut.key == "v" && shortcut.modifiers.empty? }
all_pawn_list = ludo_shortcuts.find { |shortcut| shortcut.key == "v" && shortcut.modifiers == [:shift] }
assert(own_pawns_shortcut&.message == "Alice: In base: 4.", "Ludo P does not group base pawns")
assert(opponent_pawns_shortcut&.message.to_s.include?("Bob: In base: 4"), "Ludo Shift+P does not report opposing pawn positions")
assert(own_pawn_list&.kind == :browse && own_pawn_list.choices.map(&:label) == ["Alice, base"] * 4, "Ludo V does not expose one own pawn per row")
assert(all_pawn_list&.kind == :browse && all_pawn_list.choices.length == 16, "Ludo Shift+V does not expose every pawn in one list")
assert(all_pawn_list.choices.first.label == "Alice, base", "Ludo Shift+V does not identify the owner before its position")
ludo_waiting_surface = ludo.surface_spec(ludo_replay, "Alice")
ludo_track_spec = ludo_waiting_surface
assert(ludo_track_spec.is_a?(GameSurfaces::PawnTrackSpec), "Ludo still exposes a spatial board")
assert(ludo_track_spec.activation_action&.kind == "dice" && ludo_track_spec.activation_action&.name == "roll", "Ludo pawn list Enter does not roll the die")
assert(ludo_track_spec.header == "Ludo", "Ludo exposes pawn positions in the main field header")
assert(ludo_track_spec.items.map(&:label) == ["Roll the die"], "Ludo exposes pawn positions before rolling")
two_player_ludo = ludo.replay(session, [], NewGamesRepository.new(["Alice", "Bob"]))
assert(ludo.surface_spec(two_player_ludo, "Alice").items.length == 1, "Two-player Ludo did not expose the compact pawn list")
assert(ludo.surface_spec(two_player_ludo, "Bob").items.map(&:label) == ["Waiting for a move: Alice"], "Ludo exposes pawn positions while waiting")
ludo_events = [{ "id" => 1, "actor" => "Alice", "action" => "roll", "value" => "6" }]
ludo_rolled = ludo.replay(session, ludo_events, ludo_repository)
assert(ludo_rolled.state[:phase] == :moving, "A Ludo 6 did not open pawn selection")
assert(ludo.legal_actions(ludo_rolled, "Alice").length == 4, "A Ludo 6 cannot release every base pawn")
invalid_pawn_status, = ludo.action_for({ "kind" => "pawn", "action" => "move" }, ludo_rolled, "Alice")
assert(invalid_pawn_status == :invalid_move, "Ludo treated a missing pawn number as pawn 1")
move_surface = ludo.surface_spec(ludo_rolled, "Alice")
assert(move_surface.items.length == 4, "Ludo did not list every legal pawn choice")
assert(move_surface.items.all? { |item| item.label.include?("base") && item.label.include?("track 1") }, "Ludo move choices do not preview semantic destinations")
assert(ludo.describe_event(ludo_events.first, ludo_repository, ludo_rolled, "Bob").include?("Alice rolled 6."), "Ludo did not announce a die roll")
ludo_after = append_surface_action(ludo, session, ludo_repository, ludo_events, ludo_rolled, "Alice", ludo.legal_actions(ludo_rolled, "Alice").first)
assert(ludo_after.state[:pawns][0].count(0) == 1, "Ludo did not move a pawn out of the base")
assert(ludo_after.current_player == "Alice" && ludo_after.state[:phase] == :awaiting_roll, "Ludo did not award the classic extra roll after a 6")
assert(
  ludo.describe_event(ludo_events.last, ludo_repository, ludo_after, "Bob").to_s.include?("Alice moved pawn"),
  "Ludo did not expose its pawn-move announcement"
)
assert(ludo.game_shortcuts(ludo_after, "Alice").find { |shortcut| shortcut.key == "p" && shortcut.modifiers.empty? }.message == "Alice: In base: 3; track 1.", "Ludo P did not report semantic pawn positions")
finished_pawns = Marshal.load(Marshal.dump(ludo_after))
finished_pawns.state[:pawns][0] = [GameRoomGames::Ludo::FINISH_PROGRESS, 0, -1, -1]
assert(
  ludo.game_shortcuts(finished_pawns, "Alice").find { |shortcut| shortcut.key == "p" && shortcut.modifiers.empty? }.message == "Alice: In base: 2; track 1; At the finish: 1 of 4 pawns.",
  "Ludo P did not aggregate pawns that reached the finish"
)
finish_state = ludo_replay.state.merge(
  phase: :moving, roll: 2, pawns: [[56, -1, -1, -1], [-1, -1, -1, -1], [-1, -1, -1, -1], [-1, -1, -1, -1]]
)
assert(!ludo.send(:legal_pawn_indices, finish_state, 0).include?(0), "Ludo allowed a pawn to overshoot the finish")
finish_state[:roll] = 1
assert(ludo.send(:legal_pawn_indices, finish_state, 0).include?(0), "Ludo rejected an exact finishing roll")
finished_state = Marshal.load(Marshal.dump(finish_state))
finished_state[:pawns][0][0] = GameRoomGames::Ludo::FINISH_PROGRESS
[true, false].each do |exact_finish|
  finished_state[:options]["exact_finish"] = exact_finish
  assert(
    !ludo.send(:legal_pawn_indices, finished_state, 0).include?(0),
    "Ludo allowed a pawn at the finish to move when exact_finish was #{exact_finish}"
  )
end

# When only one move exists, the roll and move are one replayed server event.
# Replaying that same event cannot submit or apply a second move.
forced_events = ludo_events + [{ "id" => 3, "actor" => "Alice", "action" => "roll", "value" => "2" }]
forced_replay = ludo.replay(session, forced_events, ludo_repository)
assert(forced_replay.state[:pawns][0][0] == 2, "Ludo did not perform the only legal pawn move automatically")
assert(forced_replay.current_player == "Bob", "Ludo did not advance after its automatic pawn move")
forced_messages = ludo.describe_event(forced_events.last, ludo_repository, forced_replay, "Bob")
assert(forced_messages.any? { |message| message.include?("rolled 2") }, "The automatic move lost its roll announcement")
assert(forced_messages.any? { |message| message.include?("track 1 to track 3") }, "The automatic move lost its semantic move announcement")
forced_again = ludo.replay(session, forced_events, ludo_repository)
assert(forced_again.state[:pawns] == forced_replay.state[:pawns], "Replaying an automatic move applied it twice")

capture_state = ludo.send(:initial_state, ludo_players, ludo.default_options)
capture_state[:current_player] = "Alice"
capture_state[:phase] = :moving
capture_state[:roll] = 2
capture_state[:pawns][0][0] = 0
# Bob's progress 41 and Alice's progress 2 both refer to shared track field 3.
capture_state[:pawns][1][0] = 41
capture_history = []
ludo.send(:apply_pawn_move_index!, capture_state, "Alice", 0, 0, 501, capture_history)
assert(capture_state[:pawns][1][0] == -1, "Ludo did not return the captured pawn to its base")
assert(
  capture_history.any? { |entry| entry.kind == :capture && entry.text == "Alice sent pawn 1 belonging to Bob back to the base." },
  "Ludo capture announcement does not identify the captured pawn and its owner"
)

ludo_rules = ludo.rule_book.sections.flat_map(&:paragraphs).join(" ")
assert(ludo_rules.include?("1, 14, 27 and 40"), "Ludo rules do not explain the different shared-track starting fields")
assert(ludo_rules.include?("passing from 52 back to 1"), "Ludo rules do not explain shared-track wrapping")

puts 'PASS ludo: model rules and presentation'
