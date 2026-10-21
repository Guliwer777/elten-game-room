require_relative "../support/session_runner"

h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: ["Alice"], bots: 1, options: {'bot_delay' => 0})
h.start
visible = true
r = runner_for(h, covered: -> { !visible })
old = h.replay("Alice")
assert(submit(h, r).first == :ok, "human action rejected")
step(h, r)
assert(h.events("Alice").length == 1, "worker overtook visible presentation")
r.publish_view(session: h.session, replay: h.replay("Alice"), busy: true,
  context: GameRoomGames::ActionContext.new)
step(h, r)
assert(h.events("Alice").length == 1, "worker ignored serial presentation")
visible = false
step(h, r, count: 2)
assert(h.events("Alice").length == 2, "covered owner did not play the bot")
assert(h.events("Alice").last["actor"].start_with?("bot:"), "worker impersonated a human")
50.times { step(h, r) }
assert(h.events("Alice").length == 2, "worker duplicated a bot or played a human")
begin
  h.as("Alice") { r.submit(session: h.session, replay: old, selection: {"x" => 0, "y" => 0}, actor: "Alice") }
  raise "stale view was accepted"
rescue GameRoomSessionRunner::StaleView
end
visible = true
submit(h, r)
r.publish_view(session: h.session, replay: h.replay("Alice"), busy: false,
  context: GameRoomGames::ActionContext.new)
# The existing TurnController includes its normal post-confirmation interval.
r.instance_variable_get(:@turn).instance_variable_set(:@ready_at, 0.0)
step(h, r, count: 3)
assert(h.events("Alice").length == 4, "foreground and background did not share the same executor")
r.close
count = h.events("Alice").length
step(h, r, count: 5)
assert(h.events("Alice").length == count, "closed runner wrote a move")
assert(h.transports["Alice"].instance_variable_get(:@session_feeds).empty?, "feed leaked on close")

# Neither reader steals notifications from the other reader/screen.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
rs = h.users.to_h { |u| [u, runner_for(h, u)] }
7.times do
  current = h.replay("Alice")
  break if current.finished?
  u = current.current_player
  assert(submit(h, rs[u], u).first == :ok, "normal human action failed")
  h.users.each { |name| step(h, rs[name], name) }
  h.assert_converged("human exchange")
end
assert(h.replay("Alice").finished?, "test did not finish the match")
assert(h.transports["Bob"].consume_game_change(h.session["__id"]), "background reader consumed UI notification")
assert(h.transports["Alice"].room_snapshot(h.table)[:table]["status"] == "waiting", "completion did not update room status")
old_session = h.session
h.start
h.users.each { |u| step(h, rs[u], u, count: 3) }
assert(rs.values.all? { |runner| runner.instance_variable_get(:@session)["__id"] == h.session["__id"] }, "covered reader missed rematch")
begin
  h.as("Alice") { rs["Alice"].submit(session: old_session, replay: h.replay("Alice"), selection: {}, actor: "Alice") }
  raise "old session was accepted"
rescue GameRoomSessionRunner::StaleView
end
rs.each_value(&:close)

# A private local draft is valid only for its own round. Its identity is not
# derived from the whole revision, since another player's commitment changes it.
game = GameRoomGames::Categories.new
state = {round: 1, phase: :answering}
replay = Struct.new(:state).new(state)
first = game.automatic_surface_identity(replay)
state[:round] = 2
assert(first != game.automatic_surface_identity(replay), "answer snapshot could leak into next round")

# Delayed native delivery, duplicate callbacks and a server gap preserve IDs.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
rs = h.users.to_h { |u| [u, runner_for(h, u)] }
h.broker.automatic_delivery = false
submit(h, rs["Alice"])
h.broker.deliver(user: "Bob", duplicate: true)
h.users.each { |u| step(h, rs[u], u, count: 3) }
h.assert_converged("delayed delivery", expected_count: 1)
rs.each_value(&:close)

# No server requests just because the local worker's deadline tick ran.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
step(h, r, count: 8)
reads = 0
provider = r.instance_variable_get(:@room_snapshot_provider)
r.instance_variable_set(:@room_snapshot_provider, -> { reads += 1; provider.call })
checks = 0
model = r.instance_variable_get(:@game)
policy = model.method(:automatic_action)
model.define_singleton_method(:automatic_action) { |*a, **kw| checks += 1; policy.call(*a, **kw) }
step(h, r, count: 100)
assert(reads == 0, "idle executor polled room state")
assert(checks == 0, 'idle executor repeatedly invoked non-deadline automatic policy')
r.close

puts "Game session runner: foreground/background, bots, human commits, stale views, rematch, completion, draft identity, delivery, cleanup and idle checks passed"
