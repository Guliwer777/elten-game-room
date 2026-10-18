require_relative '../support/session_runner'
require_relative '../support/categories'
require_relative '../support/sequence_random'

game = GameRoomGames::Categories.new
users = Array.new(game.maximum_players) do |index|
  "player#{index}".ljust(GameRepository::MAX_PLAYER_LENGTH, ('a'.ord + index).chr)
end
successor = 'observer'.ljust(GameRepository::MAX_PLAYER_LENGTH, 'z')
assert(users.length == 8 && users.all? { |user| user.length == 64 }, 'Maximum-name/seat fixture is incomplete')
options = game.normalize_options(game.default_options.merge('category_set' => 'custom',
  'custom_categories' => %w[country city], 'round_category_count' => 2, 'round_time' => 0,
  'judge_mode' => 'master'))

# The strongest model payload contains all eight original seats. The new
# permanent judge is supplied only by authenticated controller metadata.
repository = CategoriesRepository.new(users)
session = {'options' => JSON.generate(options)}
context = GameRoomGames::ActionContext.new(session_id: 1701, table_id: 1702, now: 100,
  table_owner: users.first, random_source: GameRoomRandom::SequenceSource.new([1]))
events = []
replay = game.replay(session, events, repository)
status, plan = game.action_for(game.automatic_action(replay, users.first, context: context),
  replay, users.first, context: context)
assert(status == :ok, 'Maximum-seat round setup failed')
append_plan(events, plan, users.first)
replay = game.replay(session, events, repository)
context.table_owner = successor
selection = game.membership_action(replay, members: [successor], table_owner: successor)
status, plan = game.action_for(selection, replay, users.first, context: context)
assert(status == :ok, 'Full-roster departure plan was rejected')
GameRoomEventProtocol.validate_commands!(plan.events)
command = GameRoomEventProtocol.normalized(plan.events.fetch(0))
assert(GameRoomEventProtocol.valid_wire_command?(command), 'Membership command violates the production wire contract')
assert(command['value'].length <= GameRepository::MAX_VALUE_LENGTH, 'Membership payload is too long for the runner')
assert(users.none? { |user| command['value'].include?(user) } && !command['value'].include?(successor),
  'Membership wire value repeats authenticated player names')
encoded = JSON.parse(command.fetch('value'))
assert(encoded[1] == (0...8).to_a, 'The eighth seat was lost from the compact payload')
append_plan(events, plan, users.first)
events.last.merge!('__controller' => true, '__authority_user' => successor, '__insertion_user' => successor)
after = game.replay(session, events, repository)
assert(after.state[:departed_players] == users && after.state[:permanent_judge] == successor,
  'Full-roster departure did not preserve the authenticated observer judge')
assert(after.state[:phase] == :interrupted && !after.finished? && !after.winner,
  'A lone observer judge acquired a fabricated game result')

# Preserve the exact size characteristic of the live failure: the previous
# descriptive object already exceeded 64 characters for a normal test name.
old_wire = JSON.generate('attempt' => 1, 'seats' => [0], 'judge' => 'papiertestowy2', 'judge_left' => false)
assert(old_wire.length > GameRepository::MAX_VALUE_LENGTH, 'Old-format size control no longer models the live failure')

# Actual managed worker + local native broker, not manual step/refresh.
# Several membership callbacks may coalesce; each packet must fit and all
# seven departed seats must disappear, including seat index seven.
h = NativeRoomHarness.new(game: game, users: users, options: options)
h.start
context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
  now: Time.now.to_i, table_owner: users.first, random_source: GameRoomRandom::LocalSecureSource.new)
h.submit(users.first, context: context)
runner = runner_for(h, users.first, covered: -> { false })
previous_user = $game_room_test_user
$game_room_test_user = users.first
wait_until = lambda do |label, &check|
  limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  loop do
    value = check.call
    break value if value
    error = runner.take_error
    raise error if error
    raise "Timed out: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= limit
    sleep 0.01
  end
end
begin
  runner.start
  wait_until.call('initial long-name worker view') { runner.presentation_snapshot }
  users.drop(1).each do |user|
    h.as(user) do
      LobbyRepository.new(ProgramDouble.new(h.broker.endpoint(user)), transport: h.transports.fetch(user),
        server_tables: Object.new).leave_table(h.table, user)
    end
  end
  snapshot = wait_until.call('automatic long-name departure without refresh') do
    current = runner.presentation_snapshot
    current if current && current.session['__aborted'] && current.replay.state[:departed_players].length == 7
  end
  assert(snapshot.replay.state[:departed_players].sort == users.drop(1).sort,
    'Native worker removed the wrong long-name participant')
  removals = snapshot.replay.accepted_events.select { |event| event['action'] == 'participants_departed' }
  assert(!removals.empty? && removals.all? { |event| GameRoomEventProtocol.valid_wire_command?(event) },
    'Native worker sent an invalid departure command')
  seats = removals.flat_map { |event| JSON.parse(event['value'])[1] }
  assert(seats.sort == (1..7).to_a, 'Membership callbacks lost or duplicated a native seat')
  assert(snapshot.replay.state[:phase] == :interrupted && !snapshot.replay.winner,
    'Long-name worker interruption manufactured a winner')
  puts "PASS Categories departure wire: old=#{old_wire.length}, all-eight=#{command['value'].length}, max-name=#{users.first.length}; native threaded 8 seats, no manual step/refresh"
ensure
  runner.close
  runner.join
  $game_room_test_user = previous_user
end
