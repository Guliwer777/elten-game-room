require_relative "../support/native_room_harness"
require_relative "../support/log"

h = NativeRoomHarness.new(users: %w[Alice Bob Carol Dave])
created = h.core.entries.find { |entry| entry["packet"]["kind"] == "room_created" }["packet"]
h.start
h.write("Alice", [GameRoomGames::EventCommand.new(action: "tick", value: "before")])
h.broker.automatic_delivery = false
start = h.core.entries.find { |entry| entry["packet"]["kind"] == "game_started" }["packet"]
action = h.core.entries.find { |entry| entry["packet"]["kind"] == "game_action" }["packet"]
state = { "version" => 2, "kind" => "room_state", "actor" => "Alice",
  "data" => { "bot_count" => 0, "status" => "waiting", "updated_at" => 100 } }
packets = []
mutate = lambda do |original, path, values|
  values.each do |value|
    copy = JSON.parse(JSON.generate(original))
    target = path[0...-1].inject(copy) { |part, key| part[key] }
    target[path.last] = value
    packets << copy
  end
end
mutate.call(start, ["version"], [nil, [], {}, "2", true, 3])
mutate.call(start, ["actor"], [nil, [], {}, true, 3])
mutate.call(start, ["data"], [nil, [], true, "bad"])
mutate.call(start, ["data", "players"], [nil, "bad", {}, true, 3, [], [nil], ["Alice", {}]])
mutate.call(start, ["data", "options"], [nil, [], {}, "[]", "broken JSON"])
mutate.call(start, ["data", "created_at"], [nil, [], {}, -1, "123"])
mutate.call(start, ["data", "session_id"], [nil, [], {}, true, "1", 0])
mutate.call(action, ["data", "sequence"], [nil, [], {}, true, -1, "0"])
mutate.call(action, ["data", "events"], [nil, "bad", {}, true, [nil], [], [["wrong"]]])
mutate.call(action, ["data", "events", 0, "action"], [nil, [], {}, "", "x" * 33])
mutate.call(action, ["data", "events", 0, "value"], [nil, [], {}, 5, "x" * 65])
mutate.call(action, ["data", "events", 0, "move_id"], [nil, [], {}, ""])
mutate.call(state, ["data", "bot_count"], [nil, [], {}, "3", -1, 9])
mutate.call(state, ["data", "status"], [nil, [], {}, "bogus"])
mutate.call(state, ["data", "updated_at"], [nil, [], {}, "now"])
marker = {"publication_ref" => {"author" => "Alice", "publication_key" => "fixture"},
  "schedule_id" => "a" * 64, "match_id" => "b" * 64, "leg" => 1}
mutate.call(created, ["data", "tournament_match"], [nil, [], {},
  marker.merge("leg" => 0), marker.merge("match_id" => "not-a-digest"),
  marker.merge("publication_ref" => {"author" => [], "publication_key" => "fixture"})])
packets << state.merge("data" => { "owner" => "Bob" })

# A participant cannot spoof the owner even with an otherwise well-formed
# game-start packet. Authorisation precedes shape-specific processing.
h.view("Bob").stack_push(start.merge("actor" => "Bob"), message_id: SecureRandom.uuid)
packets.each { |packet| h.view("Alice").stack_push(packet, message_id: SecureRandom.uuid) }
h.write("Alice", [GameRoomGames::EventCommand.new(action: "tick", value: "after")])
h.broker.deliver(duplicate: true)
h.users.each do |user|
  repo = h.repositories[user]
  assert(repo.session_for_table(h.table)["__id"] == h.session["__id"], "#{user}: invalid start replaced the game")
  assert(repo.snapshot_for(h.session, force_events: true).events.map { |event| event["value"] } == %w[before after], "#{user}: invalid packet blocked/altered later events")
  assert(h.transports[user].room_snapshot(h.table)[:table]["owner"] == "Alice", "invalid state changed owner")
end
h.assert_converged("malformed stack packets", expected_count: 2)
puts "Native packet validation tests passed: #{packets.length + 1} invalid packets, four clients"
