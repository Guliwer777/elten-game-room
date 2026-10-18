# encoding: UTF-8
require_relative "../../support/quiz_party_review_regressions"

f = QuizReviewFixture.new
assert(f.answer("Bob", question_id: "quiz-question-999-999").first == :invalid, "a stale UI selected an answer")
f.advance(1001)
plans = f.h.users.to_h { |u| [u, f.plan(u)] }
sequence = f.h.repositories["Bob"].next_sequence(f.h.session, f.h.events("Bob"))
f.h.broker.automatic_delivery = false
%w[Alice Carol Dave].each { |u| f.h.write(u, plans[u].events, sequence: sequence) }
f.h.broker.deliver(user: "Dave", duplicate: true)
f.h.broker.deliver(user: "Alice")
f.h.broker.deliver(duplicate: true)
f.h.broker.automatic_delivery = true
f.h.assert_converged("simultaneous commitments")
assert(f.h.replay("Alice").state[:commitments].length == 3, "concurrent answers were dropped")

f.advance(1005)
assert(f.answer("Bob").first == :invalid, "a new answer was allowed after the deadline")
assert(f.game.legal_actions(f.h.replay("Bob"), "Bob", context: f.contexts["Bob"]).empty?, "bot can keep answering after time")
# The grace permits transport latency, not unbounded new answers.
f.advance(1007)
before = f.h.events("Bob")
command = plans["Bob"].events.first
sample = before.last.merge("__id" => 9999, "id" => 9999, "actor" => "Bob", "__insertion_user" => "Bob", "action" => command.action, "value" => command.value, "created_at" => 1007)
r = f.game.replay(f.h.session, before + [sample], f.h.repositories["Bob"])
assert(r.state[:commitments].key?("Bob"), "an in-flight answer within grace was discarded")
sample["created_at"] = 1100
r = f.game.replay(f.h.session, before + [sample], f.h.repositories["Bob"])
assert(!r.state[:commitments].key?("Bob"), "replay accepted an answer 95 seconds late")

f.advance(1008)
f.auto("Alice")
old_reveals = {}
%w[Alice Carol Dave].each do |u|
  r = f.h.replay(u)
  action = f.game.automatic_action(r, u, context: f.contexts[u])
  status, plan = f.game.action_for(action, r, u, context: f.contexts[u])
  assert(status == :ok && plan.events.all? { |e| e.value.bytesize <= 64 }, "reveal exceeds the wire limit")
  old_reveals[u] = plan
  f.h.write(u, plan.events)
end
f.auto("Alice")
f.h.assert_converged("first question scored")
f.advance(1012)
f.auto("Alice")
f.h.write("Bob", plans["Bob"].events, sequence: sequence)
f.h.assert_converged("old answer delivered during question two")
assert(!f.h.replay("Bob").state[:commitments].key?("Bob"), "old answer blocked the new question")
f.h.users.each { |u| f.h.write(u, f.plan(u).events) }
f.auto("Alice")
f.h.write("Alice", old_reveals["Alice"].events, sequence: sequence)
assert(f.h.replay("Alice").state[:reveal_parts].empty?, "old reveal poisoned the new question")
current = f.h.replay("Alice")
_, partial = f.game.action_for({ "kind" => "automatic", "action" => "reveal" }, current, "Alice", context: f.contexts["Alice"])
f.h.write("Alice", partial.events.first(1))
# Resending the full plan after only one accepted fragment must still work.
f.h.users.each { |u| f.auto(u) }
f.auto("Alice")
f.h.assert_converged("new question and stale reveal fragments")
assert(f.h.replay("Bob").state[:scores]["Bob"] == 1, "the valid second answer did not score")

# All clients lost their local envelopes after committing. The owner must still
# close the question at the reveal timeout, without continuously retrying reveal.
f.advance(1016)
f.auto("Alice")
f.h.users.each { |u| f.h.write(u, f.plan(u).events) }
f.auto("Alice")
f.contexts.each_value { |c| c.hidden_submissions = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new) }
assert(f.game.automatic_action(f.h.replay("Alice"), "Alice", context: f.contexts["Alice"]) == nil, "missing data caused a busy reveal loop")
assert(f.game.legal_actions(f.h.replay("Bob"), "Bob", context: f.contexts["Bob"]).empty?, "a bot repeatedly requests an impossible reveal")
broken = f.contexts["Alice"].dup
broken.hidden_submissions = Object.new
broken.hidden_submissions.define_singleton_method(:reveal) { |**_arguments| raise TypeError, "damaged local envelope" }
assert(f.game.automatic_action(f.h.replay("Alice"), "Alice", context: broken) == nil, "corrupt local data caused a busy reveal loop")
f.advance(1031)
assert(f.game.automatic_action(f.h.replay("Alice"), "Alice", context: f.contexts["Alice"])["action"] == "finish_question", "missing owner envelope starved the timeout")
f.auto("Alice")
f.h.assert_converged("lost owner and guest envelopes")
assert(f.h.replay("Alice").state[:phase] == :drawing, "round stalled on missing envelopes")

# Result ordering for small tables; larger-table observers get counts once.
replay = f.h.replay("Alice")
observer = f.game.history_entries_for_display(replay, "Observer").select { |e| e.kind == :answer_result }
assert(observer.length == 3 && observer.all? { |e| e.text.include?("answered correctly") }, "observer lost or duplicated question summaries")
small = replay.dup
small.state = replay.state.merge(players: %w[Alice Bob Carol])
small.history = replay.history.reject { |e| e.actor == "Dave" && e.kind == :answer_result }
%w[Alice Bob Carol].each do |viewer|
  groups = f.game.history_entries_for_display(small, viewer).select { |e| e.kind == :answer_result }.group_by(&:event_id)
  assert(groups.values.all? { |entries| entries.first.actor == viewer }, "own result was not first for #{viewer}")
end

# Use the real screen deadline dispatcher and controlled repository writes for
# an owner excluded from the match by build 215's observer role.
$quiz_regression_now = 2000
game = GameRoomGames::QuizParty.new
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol], options: game.default_options.merge("answer_time" => 5))
h.as("Alice") { h.transports["Alice"].set_observer(h.table, true, actor: "Alice") }
session = h.as("Alice") { h.repositories["Alice"].start_session(table: h.table, game: game.id, players: %w[Bob Carol], options: JSON.generate(game.default_options.merge("answer_time" => 5))) }
h.instance_variable_set(:@session, session)
ctx = GameRoomGames::ActionContext.new(session_id: session["__id"], table_id: h.table["__id"], now: 2000,
  random_source: GameRoomRandom::SeededSource.new(3), hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
  server_random: session['__server_random'] == GameRoomServerRandom::VERSION)
screen = GameScreen.allocate
{ game: game, table_owner: "Alice", repository: h.repositories["Alice"], session: session, table: h.table }.each { |key, value| screen.instance_variable_set("@#{key}", value) }
screen.define_singleton_method(:action_context) { ctx }
screen.define_singleton_method(:game_recipients) { h.users }
screen.define_singleton_method(:network_task) { |_label, &block| block.call }
run_owner = -> { h.as("Alice") { assert(screen.send(:perform_automatic_action, h.replay("Alice")), "observing owner failed to advance") } }
run_owner.call
r = h.replay("Bob")
h.submit("Bob", { "kind" => "question", "action" => "submit", "question_id" => game.send(:category_surface_id, r.state), "answer" => r.state[:choices].first }, context: ctx)
run_owner.call
ctx.now = $quiz_regression_now = 2008
h.as("Alice") { assert(screen.send(:automatic_action_due?, h.replay("Alice")), "observer deadline did not wake up") }
run_owner.call
run_owner.call # no commitments; no reveal to await
ctx.now = $quiz_regression_now = 2012
h.as("Alice") { assert(screen.send(:automatic_action_due?, h.replay("Alice")), "observer's next-question pause never ended") }
run_owner.call
h.assert_converged("observer controls question transitions")
assert(h.replay("Alice").state[:position] == 2, "observer did not start the second question")
guests = %w[Bob Carol].to_h do |user|
  personal = ctx.dup
  personal.hidden_submissions = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
  [user, personal]
end
guests.each do |user, personal|
  r = h.replay(user)
  h.submit(user, game.legal_actions(r, user, context: personal).first, context: personal)
end
run_owner.call
h.as("Alice") do
  assert(!screen.send(:perform_automatic_action, h.replay("Alice")), "observer attempted to reveal a guest's private answer")
end
guests.each { |user, personal| h.submit(user, context: personal) }
run_owner.call
h.assert_converged("observer and guests reveal only their own answers")
controlled = h.events("Alice").find { |event| event["__controller"] }
assert(controlled != nil && h.repositories["Alice"].actor_of(controlled, session) == "Bob", "controlled actor was lost during replay")
assert(h.repositories["Alice"].actor_of(controlled.merge("__insertion_user" => "Carol"), session).empty?, "a guest impersonated the controller")
assert(h.repositories["Alice"].actor_of(controlled.merge("actor" => "Outsider"), session).empty?, "controller selected an actor outside the match")
puts "Quiz review regressions passed: stale/concurrent answers, grace, lost envelopes, results and observing owner"
