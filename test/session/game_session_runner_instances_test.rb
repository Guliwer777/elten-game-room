require_relative "../support/session_runner"

# An old covered window must not play past a newer visible window's serial
# presentation. This failed with independent per-screen background executors.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: ['Alice'], bots: 1, options: {'bot_delay' => 0})
h.start
old_covered, new_covered = true, false
old = runner_for(h, covered: -> { old_covered })
newer = runner_for(h, covered: -> { new_covered })
[old, newer].each { |r| r.send(:register_execution_group) }
assert(old.instance_variable_get(:@execution_group).equal?(newer.instance_variable_get(:@execution_group)),
  'two screens did not share an execution group')
assert(submit(h, newer).first == :ok, 'active screen could not submit')
newer.publish_view(session: h.session, replay: h.replay('Alice'), busy: true,
  context: GameRoomGames::ActionContext.new)
step(h, old)
step(h, newer)
assert(h.events('Alice').length == 1, 'covered duplicate ran the bot past the visible presentation')
begin
  submit(h, old)
  raise 'inactive duplicate was allowed to submit'
rescue GameRoomSessionRunner::StaleView
end
new_covered = true
step(h, old)
assert(h.events('Alice').length == 1, 'two covered screens both drove the match')
step(h, newer, count: 2)
assert(h.events('Alice').length == 2, 'most recent covered screen did not run the bot')

# Returning to the older window transfers execution and reconciles its state;
# closing the other window does not destroy the remaining execution group.
old_covered = false
old.publish_view(session: h.session, replay: h.replay('Alice'), busy: false,
  context: GameRoomGames::ActionContext.new)
step(h, old, count: 2)
assert(old.instance_variable_get(:@replay).accepted_events.length == 2, 'handover retained old state')
newer.close
newer.send(:unregister_execution_group)
assert(!GameRoomSessionRunner::GROUPS.empty?, 'closing one screen discarded the other executor')
assert(submit(h, old).first == :ok, 'remaining screen could not submit after handover')
old.close
old.send(:unregister_execution_group)
assert(GameRoomSessionRunner::GROUPS.empty?, 'execution group leaked after last screen closed')

# Changing screens must not bypass an uncertain write's recovery delay.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
first_covered, second_covered = false, true
a = runner_for(h, covered: -> { first_covered })
b = runner_for(h, covered: -> { second_covered })
[a, b].each { |r| r.send(:register_execution_group) }
step(h, a)
group = a.instance_variable_get(:@execution_group)
a.synchronize { group.defer(30.0) }
first_covered, second_covered = true, false
step(h, b)
assert(b.instance_variable_get(:@sync).waiting?, 'new screen bypassed account/table recovery backoff')
[a, b].each { |r| r.close; r.send(:unregister_execution_group) }
assert(GameRoomSessionRunner::GROUPS.empty?, 'recovery handover leaked group')
puts 'Multiple screens: one executor, shared lock, presentation, handover, backoff and cleanup passed'
