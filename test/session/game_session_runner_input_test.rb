require_relative "../support/session_runner"
require 'timeout'

game = GameRoomGames::Uno.new
h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 1,
  options: game.default_options.merge('interceptions' => true, 'bot_delay' => 0))
h.start
players = h.repositories['Alice'].players_for(h.session)
sim_repo = GameRoomSimulation::Repository.new(players)
selection, deal_seed = nil, nil
(1..200).each do |seed|
  next unless seed.even? # The bot must own the next turn so its planner runs.
  candidate = {'actor' => 'Alice', 'action' => 'deal', 'value' => "1|0|#{seed.to_s(16).rjust(32, '0')}|0", 'id' => 1}
  position = game.replay(h.session, [candidate], sim_repo)
  card = position.state[:hands]['Alice'].find { |id| game.send(:interceptable?, position.state, id) }
  next unless card && card[1].match?(/[0-9]/)
  selection = {'kind' => 'card', 'action' => 'select', 'card_id' => card, 'card' => card}
  deal_seed = seed
  break
end
assert(deal_seed, 'could not prepare deterministic legal UNO interception')
deal = lambda do |room|
  room.view('Alice').next_random_values = deal_seed.to_s(16).rjust(32, '0').scan(/../).map { |byte| byte.to_i(16) + 1 }
  context = GameRoomGames::ActionContext.new(now: 1_000,
    random_source: GameRoomRandom::LocalSecureSource.new)
  room.submit('Alice', {'kind' => 'command', 'action' => 'deal'}, context: context)
  assert(room.view('Alice').calls[:random] == 1, 'fixture bypassed the authenticated server draw')
  assert(room.events('Alice').length == 1 && room.replay('Alice').accepted_events.length == 1,
    'server draw did not produce one accepted deal')
end
deal.call(h)
r = runner_for(h)
entered, release = Queue.new, Queue.new
coordinator = r.instance_variable_get(:@coordinator)
original = coordinator.method(:decide_next)
coordinator.define_singleton_method(:decide_next) do |**args|
  entered << true
  release.pop
  original.call(**args)
end
planning = Thread.new { h.as('Alice') { r.step } }
Timeout.timeout(3) { entered.pop }
input = Thread.new do
  h.as('Alice') { r.submit(session: h.session, replay: h.replay('Alice'), selection: selection, actor: 'Alice') }
end
accepted_while_planning = input.join(0.5)
release << true
assert(planning.join(5), 'planner did not finish')
assert(input.join(5), 'input did not finish')
r.close
assert(accepted_while_planning, 'bot planning blocked a legal interception and chat/network tasks')
assert(input.value.first == :ok, 'interception failed during calculation')
assert(h.events('Alice').size == 2, 'stale bot decision was committed after the interception')
assert(h.replay('Alice').state[:hands]['Alice'].none? { |id| id == selection['card_id'] }, 'card did not leave hand')
puts 'UNO real interception is accepted during planning; obsolete decision discarded without changing strategy'

# A prior unrelated attempt changes the event revision, not the physical card
# or round. Preserve UNO's usual late-attempt rules instead of discarding Enter.
h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 1,
  options: game.default_options.merge('interceptions' => true, 'bot_delay' => 0))
h.start
deal.call(h)
r = runner_for(h)
old = h.replay('Alice')
wrong = old.state[:hands]['Alice'].find { |id| !game.send(:interceptable?, old.state, id) }
attempt = {'kind' => 'card', 'action' => 'select', 'card_id' => wrong, 'card' => wrong}
h.as('Alice') { assert(r.submit(session: h.session, replay: old, selection: attempt, actor: 'Alice').first == :ok, 'late attempt rejected') }
h.as('Alice') { assert(r.submit(session: h.session, replay: old, selection: selection, actor: 'Alice').first == :ok, 'changed revision swallowed real interception') }
assert(h.events('Alice').size == 3, 'interception/late attempt changed event count')
assert(h.replay('Alice').state[:scores]['Alice'] == 3, 'late penalty changed')
r.close
later_round = Marshal.load(Marshal.dump(old))
later_round.state[:round] += 1
assert(!game.concurrent_session_input?(old, later_round, selection), 'old card leaked into next round')
puts 'UNO revision race preserves late penalties and cannot cross round boundaries'

# A covered window does not dispatch its timers during a long calculation.
# The callback queued during that calculation must be ingested before commit,
# not one tick after an obsolete bot action has already been sent.
h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 1,
  options: game.default_options.merge('interceptions' => true, 'bot_delay' => 0))
h.start
deal.call(h)
r = runner_for(h)
queued, ingested = false, false
transport = h.transports['Alice']
dispatch = transport.method(:dispatch_pending_events)
transport.define_singleton_method(:dispatch_pending_events) do
  if queued && !ingested
    ingested = true
    status, plan = game.action_for(selection, h.replay('Alice'), 'Alice', context: r.send(:context))
    assert(status == :ok, 'queued interception fixture was invalid')
    h.write('Alice', plan.events)
  end
  dispatch.call
end
coordinator = r.instance_variable_get(:@coordinator)
decide = coordinator.method(:decide_next)
coordinator.define_singleton_method(:decide_next) do |**args|
  result = decide.call(**args)
  queued = true
  result
end
step(h, r)
assert(ingested, 'post-planning queued callback was not dispatched before revision check')
assert(h.events('Alice').size == 2, 'bot committed past a queued interception')
r.close
puts 'Covered planner drains received callbacks before committing its decision'
