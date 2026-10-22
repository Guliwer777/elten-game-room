require_relative "../support/session_runner"

[:before, :after].each do |failure|
  h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
  h.start
  runner = runner_for(h)
  tick = 0.0
  sync = runner.instance_variable_get(:@sync)
  sync.instance_variable_set(:@clock, -> { tick })
  h.broker.automatic_delivery = false
  h.view('Alice').fail_next_push = failure
  begin
    submit(h, runner)
    raise 'uncertain write did not fail'
  rescue EltenAPI::LiveSessions::TimeoutError
  end
  # No second Enter may create a new action identity during recovery.
  begin
    submit(h, runner)
    raise 'uncertain action was blindly repeated'
  rescue GameRoomSessionRunner::StaleView
  end
  count = h.core.entries.length
  step(h, runner, count: 20)
  assert(h.core.entries.length == count, 'recovery ignored retry delay')
  tick = 31.0
  step(h, runner, count: 5)
  h.broker.deliver(duplicate: true)
  h.assert_converged("lost acknowledgement #{failure}", expected_count: 1)
  assert(h.replay('Alice').current_player == 'Bob', 'uncertain human action was lost/repeated')
  runner.close
end

h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: ['Alice'], bots: 1, options: {'bot_delay' => 0})
h.start
r = runner_for(h)
submit(h, r)
h.as('Alice') { h.transports['Alice'].freeze_game(h.session, frozen: true) }
step(h, r, count: 10)
assert(h.events('Alice').length == 1, 'bot moved across a confirmed save/freeze boundary')
h.as('Alice') { h.transports['Alice'].freeze_game(h.session, frozen: false) }
step(h, r, count: 4)
assert(h.events('Alice').length == 2, 'unfreezing failed to resume the bot')
submit(h, r)
h.as('Alice') { h.transports['Alice'].abort_game(h.session) }
step(h, r, count: 4)
assert(h.events('Alice').length == 3, 'aborted match produced another bot move')
r.close

# A close during a bounded write must let that write finish, without scheduling
# the next turn, killing a thread, or leaving the operation lock held.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
repo = h.repositories['Alice']
entered, release = Queue.new, Queue.new
original = repo.method(:append_events)
repo.define_singleton_method(:append_events) do |**args|
  entered << true
  release.pop
  original.call(**args)
end
writer = Thread.new { h.as('Alice') { submit(h, r) } }
entered.pop
r.close
release << true
assert(writer.value.first == :ok, 'close killed a committed operation')
assert(h.events('Alice').length == 1, 'close duplicated/lost the in-flight move')
assert(r.synchronize { :free } == :free, 'operation lock leaked')

# The managed worker exits and unregisters even with no UI update on shutdown.
$game_room_test_user = 'Alice'
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
r.start
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
sleep 0.01 until r.instance_variable_get(:@snapshot) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
assert(r.instance_variable_get(:@snapshot), 'managed worker did not start')
r.close
assert(r.instance_variable_get(:@thread).join(2), 'managed worker did not finish')
assert(h.transports['Alice'].instance_variable_get(:@session_feeds).empty?, 'worker retained a transport subscription')

puts 'Runner recovery: before/after commit, backoff, freeze/resume, abort, in-flight close and real worker lifecycle passed'

h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
tick = 0.0
r.instance_variable_get(:@sync).instance_variable_set(:@clock, -> { tick })
provider = r.instance_variable_get(:@room_snapshot_provider)
broken = true
r.instance_variable_set(:@room_snapshot_provider, -> { raise EltenAPI::LiveSessions::TimeoutError, 'temporary read failure' if broken; provider.call })
h.as('Alice') { r.step }
assert(r.instance_variable_get(:@errors).size == 1, 'background failure was not recorded')
broken, tick = false, 31.0
h.as('Alice') { r.step }
assert(r.take_error.nil?, 'returning UI would repeat an already recovered outage')
assert(r.recovery_delay == 0.0, 'recovered runner retained backoff')
r.close
puts 'Returning UI does not restart historical recovery backoff'

h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
attempts = 0
model = r.instance_variable_get(:@game)
model.define_singleton_method(:automatic_action) { |*_a, **_kw| {'kind' => 'automatic', 'action' => 'unavailable'} }
model.define_singleton_method(:action_for) { |*_a, **_kw| attempts += 1; [:local_storage_unavailable, nil] }
step(h, r, count: 50)
assert(attempts == 1, 'rejected automatic action spun on every deadline tick')
assert(r.take_action_error(h.session, h.replay('Alice')) == :local_storage_unavailable, 'local failure disappeared instead of reaching foreground adapter')
assert(r.take_action_error(h.session, h.replay('Alice')).nil?, 'automatic error repeated')
r.close
puts 'Automatic rejection is paced and delivered once on the UI side'

# Captured answer sheets take the same error path; a failed local disk write
# must not be retried twenty times a second while Messages covers the screen.
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
r = runner_for(h)
attempts = 0
model = r.instance_variable_get(:@game)
model.define_singleton_method(:automatic_surface_identity) { |_replay| [:answering, 1] }
model.define_singleton_method(:automatic_surface_action) { |*_a, surface:, **_kw| surface.submission_action }
model.define_singleton_method(:action_for) { |*_a, **_kw| attempts += 1; [:local_storage_unavailable, nil] }
r.publish_view(session: h.session, replay: h.replay('Alice'), busy: false,
  context: GameRoomGames::ActionContext.new,
  surface: GameRoomSessionRunner::CapturedSurface.new({'kind' => 'answer_sheet', 'action' => 'submit'}))
step(h, r, count: 50)
assert(attempts == 1, 'captured answer retried a failed local write on every tick')
assert(r.take_action_error(h.session, h.replay('Alice')) == :local_storage_unavailable, 'captured answer failure was swallowed')
r.close
puts 'Captured draft rejection uses the same pacing and foreground error path'
