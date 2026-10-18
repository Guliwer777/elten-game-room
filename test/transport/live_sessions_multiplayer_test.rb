require_relative "../support/sequence_random"

require_relative "../support/native_room_harness"
require_relative "../support/ui"
require_relative "../../lib/game_surfaces"
require_relative "../../games/ninety_nine"
require_relative "../../games/farkle"
require_relative "../../games/categories"

ninety = NativeRoomHarness.new(game: GameRoomGames::NinetyNine.new)
ninety.start
context = GameRoomGames::ActionContext.new(session_id: ninety.session["__id"], table_id: ninety.table["__id"],
  random_source: GameRoomRandom::SeededSource.new(101), now: 1_000)
ninety.submit("Alice", { "kind" => "command", "action" => "deal" }, context: context)
ninety.assert_converged("Ninety-Nine deal")
actor = ninety.replay("Alice").current_player
ninety.submit(actor, ninety.game.legal_actions(ninety.replay(actor), actor).first)
ninety.assert_converged("Ninety-Nine atomic play/draw", expected_count: 2)
assert(ninety.events("Alice").map { |event| event["action"] } == %w[deal play_draw], "play/draw was split")

farkle = NativeRoomHarness.new(game: GameRoomGames::Farkle.new)
farkle.start
farkle.broker.automatic_delivery = false
farkle.view('Alice').next_random_values = [1, 2, 3, 4, 5, 6]
context = GameRoomGames::ActionContext.new(session_id: farkle.session["__id"], table_id: farkle.table["__id"],
  random_source: GameRoomRandom::LocalSecureSource.new, server_random: true, now: 1_000)
farkle.submit("Alice", { "kind" => "dice", "action" => "roll" }, context: context)
keep = farkle.game.legal_actions(farkle.replay("Alice"), "Alice").find do |action|
  action["action"] == "keep" && action["indices"].to_s.split(",").length == 6
end
assert(keep, "the straight cannot be kept")
farkle.submit("Alice", keep)
bank = farkle.game.legal_actions(farkle.replay("Alice"), "Alice").find { |action| action["action"] == "bank" }
farkle.submit("Alice", bank)
%w[Bob Carol Dave].each { |user| farkle.broker.deliver(user: user, duplicate: true) }
farkle.assert_converged("Farkle delayed/duplicate delivery", expected_count: 3)
assert(farkle.replay("Dave").current_player == "Bob", "Farkle turn did not advance")

# Real commit/reveal and judging, not artificial test actions. Also exercise the
# eight-person boundary: seven answer sheets with all nine categories.
[4, 8].each do |count|
  users = %w[Alice Bob Carol Dave Eve Frank Grace Heidi].first(count)
  game = GameRoomGames::Categories.new
  h = NativeRoomHarness.new(game: game, users: users, options: game.default_options.merge("round_category_count" => 9))
  h.start
  vaults = users.to_h { |user| [user, HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)] }
  contexts = users.to_h do |user|
    [user, GameRoomGames::ActionContext.new(session_id: h.session["__id"], table_id: h.table["__id"],
      hidden_submissions: vaults[user], random_source: GameRoomRandom::SequenceSource.new([1]), now: 1_000)]
  end
  h.submit("Alice", context: contexts["Alice"])
  h.broker.automatic_delivery = false
  states = users.drop(1).to_h { |user| [user, h.replay(user)] }
  plans = users.drop(1).to_h do |user|
    answers = states[user].state[:round_categories].to_h { |category| [category, (user + "ą" * 48)[0, 48]] }
    action = { "kind" => "answer_sheet", "action" => "submit", "answers" => answers }
    status, plan = game.action_for(action, states[user], user, context: contexts[user])
    assert(status == :ok, "nine-category submission failed")
    [user, plan]
  end
  # All writers choose the same logical sequence before seeing another commit.
  threads = plans.map { |user, plan| Thread.new { h.write(user, plan.events, sequence: 2) } }
  threads.each(&:value)
  h.broker.deliver
  h.assert_converged("#{count}-player concurrent commitments")
  assert(h.replay("Alice").state[:commitments].length == count - 1, "a commitment was lost")

  # After a lost acknowledgement, the stale client may retry and edit text.
  # The reveal must still match the first commitment actually accepted.
  user = users[1]
  stale = states[user]
  retry_answers = stale.state[:round_categories].to_h { |category| [category, "edited after timeout"] }
  status, retry_plan = game.action_for({ "kind" => "answer_sheet", "action" => "submit", "answers" => retry_answers },
    stale, user, context: contexts[user])
  assert(status == :ok, "stale submission could not be retried")
  h.write(user, retry_plan.events, sequence: 2)
  h.submit("Alice", context: contexts["Alice"])
  users.drop(1).each { |player| h.submit(player, context: contexts[player]) }
  h.assert_converged("#{count}-player reveals")
  assert(h.replay("Alice").state[:reveals].length == count - 1, "retry made a reveal unverifiable")
  h.submit("Alice", context: contexts["Alice"])
  reviewed = h.replay("Alice")
  assert(reviewed.state[:phase] == :review, "answering did not finish")
  # Review items are grouped by normalized answer. Use the public review spec
  # so this also covers real manual 2/1/0 assessment commands.
  surface = game.surface_spec(reviewed, "Alice")
  surface = surface.parts.map(&:surface).find { |part| part.is_a?(GameSurfaces::ReviewSpec) } if surface.is_a?(GameSurfaces::CompositeSpec)
  decisions = surface.items.to_h { |item| [item.id, item.decision_ids.include?("unique") ? "unique" : "duplicate"] }
  h.submit("Alice", { "kind" => "review", "action" => "finish", "decisions" => decisions }, context: contexts["Alice"])
  h.submit("Alice", context: contexts["Alice"])
  h.assert_converged("#{count}-player completed review")
  assert(h.replay("Alice").state[:phase] == :round_complete, "round did not finish")
end
puts "Native multiplayer tests passed: Ninety-Nine, Farkle and 4/8-player Categories"
