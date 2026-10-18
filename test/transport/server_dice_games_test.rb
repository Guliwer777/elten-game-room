require_relative '../support/session_runner'
require_relative '../../games/farkle'
require_relative '../../games/ludo'
require_relative '../../games/yahtzee'

ctx = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new, server_random: true)

# Explicit dispatch (local_view) can still wrap a real server. Only the named
# offline transaction provider, not this scheduling choice, disables native RNG.
broker = NativeLiveSessionsBroker.new
transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Alice')), local_view: true)
previous_user = Thread.current[:game_room_test_user]
begin
  Thread.current[:game_room_test_user] = 'Alice'
  table = transport.create_room(name: 'Manual dispatch', game: 'farkle', owner: 'Alice', game_options: '{}')
  assert(table['__discovery_protocol'] == GameRoomLiveSessionStore::SERVER_RANDOM_DISCOVERY_PROTOCOL,
    'a manually dispatched native endpoint lost server randomness')
ensure
  transport.close_local_view
  Thread.current[:game_room_test_user] = previous_user
end

# Keeping dice is not another chance to choose their values. Duplicate values
# are a multiset: one retained six cannot become two retained sixes.
h = NativeRoomHarness.new(game: GameRoomGames::Yahtzee.new, users: %w[Alice Bob])
h.start
h.view('Alice').next_random_values = [1, 2, 3, 4, 6]
h.submit('Alice', {'action'=>'roll'}, context: ctx)
h.view('Alice').next_random_values = [5, 5]
h.submit('Alice', {'action'=>'roll', 'die_ids'=>'d0,d2'}, context: ctx)
assert(h.replay('Alice').state[:dice] == [2, 4, 5, 5, 6], 'wrong retained or sorted dice')
assert(h.events('Alice').last['__server_random']['keep'] == [2, 4, 6], 'wrong kept multiset')
h.assert_converged('partial reroll')
before = h.replay('Alice').accepted_events.size
h.write('Alice', [GameRoomServerRandom.command(action: 'roll', count: 1, sides: 6, keep: [6, 6, 6, 6], sort: true)])
assert(h.replay('Alice').accepted_events.size == before, 'invented retained dice accepted')
h.view('Alice').next_random_values = [1]
h.submit('Alice', {'action'=>'roll', 'die_ids'=>'d4'}, context: ctx)
assert(h.replay('Alice').state[:dice] == [1, 2, 4, 5, 5], 'valid reroll after a rejected move failed')
assert(h.game.action_for({'action'=>'roll'}, h.replay('Alice'), 'Alice', context: ctx).first == :roll_limit, 'fourth roll accepted')
h.submit('Alice', {'action'=>'score', 'category'=>'chance'}, context: ctx)
h.assert_converged('reroll and score')

# Native randomness must still obey each game's phase, dice count and sides.
[[GameRoomGames::Farkle.new, 6], [GameRoomGames::Ludo.new, 1], [GameRoomGames::Yahtzee.new, 5]].each do |game, count|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  wrong = GameRoomServerRandom.command(action: 'roll', count: count, sides: 8, sort: game.id == 'yahtzee')
  h.view('Alice').next_random_values = Array.new(count, 1)
  h.write('Alice', [wrong])
  assert(h.replay('Alice').accepted_events.empty?, "#{game.id}: wrong native die accepted")
  h.view('Alice').next_random_values = Array.new(count, 1)
  h.submit('Alice', game.legal_actions(h.replay('Alice'), 'Alice', context: ctx).find { |a| a['action'] == 'roll' }, context: ctx)
  assert(h.replay('Alice').accepted_events.size == 1, "#{game.id}: valid native roll rejected")
  h.assert_converged("#{game.id}: native dice validation")
end

# Lost acknowledgements before and after commit, with/without delivery. The
# executor recovers its own request rather than planning a fresh random action.
[:before, :after].product([true, false]).each do |fault, delivery|
  h = NativeRoomHarness.new(game: GameRoomGames::Farkle.new, users: %w[Alice Bob])
  h.start
  runner = runner_for(h)
  h.broker.automatic_delivery = delivery
  h.view('Alice').fail_next_push = fault
  h.view('Alice').next_random_values = [1, 2, 3, 4, 5, 6]
  h.as('Alice') do
    begin
      runner.submit(session: h.session, replay: h.replay('Alice'), selection: {'action'=>'roll'}, actor: 'Alice')
    rescue EltenAPI::LiveSessions::TimeoutError
      # An unacknowledged write remains recoverable in the real transport.
    end
    h.transports['Alice'].reconcile(h.table['__id'])
  end
  h.broker.automatic_delivery = true
  h.broker.deliver
  step(h, runner)
  h.assert_converged("#{fault}/#{delivery}", expected_count: 1)
  assert(h.events('Alice').first['value'] == '1,2,3,4,5,6', 'retry changed the draw')
  assert(h.core.entries.count { |e| e['origin'] == 'server' } == 1, 'duplicate random record')
  runner.close
end
puts 'PASS server dice: retained dice, model validation and four executor recovery cases'
