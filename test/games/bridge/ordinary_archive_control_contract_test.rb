require_relative '../../support/session_runner'
require_relative '../../../lib/saved_games'
require_relative '../../../games/bridge'

class BridgeReviewArchiveMemory
  def initialize; @root = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@root)); end
  def update_json(_path, default:)
    data = read_json(nil, default: {})
    yield data
    @root = JSON.parse(JSON.generate(data))
  end
end

game = GameRoomGames::Bridge.new
options = game.default_options.merge('team_seats'=>[0, 0, 1, 1])
h = NativeRoomHarness.new(game:game, users:%w[Alice Bob Carol Dave], options:options)
h.start
h.submit('Alice')
4.times do |index|
  actor = h.replay('Alice').current_player
  h.submit(actor, {'kind'=>'command', 'action'=>'call', 'call'=>index.zero? ? '2H' : 'P'})
end
actor = h.replay('Alice').current_player
h.submit(actor, game.legal_actions(h.replay(actor), actor).first)
before = h.replay('Alice')
assert(before.state[:dummy_visible] && before.state[:trick].size == 1, 'fixture is not exposed dummy with an unfinished trick')
dummy = before.state[:seats][before.state[:seat_to_play]]
declarer = before.current_player
assert(dummy != declarer, 'fixture is not declarer controlling the other hand')

boundary = h.as('Alice') { h.transports['Alice'].freeze_game(h.repositories['Alice'].snapshot_for(h.session).session) }
snapshot = h.repositories['Alice'].snapshot_for(h.session)
saves = SavedGames.new(BridgeReviewArchiveMemory.new, owner:'Alice')
row = saves.put(game:game, table:h.table, snapshot:snapshot, repository:h.repositories['Alice'], now:boundary.created_at)
restored = NativeRoomHarness.new(game:game, users:h.users, options:options)
data = saves.restored_data(row, game:game, table_id:restored.table['__id'], now:Time.now.to_i + 60)
session = restored.as('Alice') do
  restored.repositories['Alice'].restore_session(table:restored.table, game:game.id,
    players:data[:players], options:row['options'], restore:data)
end
restored.instance_variable_set(:@session, session)
restored.users.each do |user|
  current = restored.replay(user)
  assert(current.state == before.state, 'ordinary archive changed exposed dummy or cards/trick')
  assert(current.history.map(&:to_h) == before.history.map(&:to_h), 'ordinary archive rewrote history')
end

# Replace dummy first: the declarer must still play that hand. The historical
# lead is immutable, even though the currently seated partner has a new name.
repo = restored.repositories['Alice']
current = repo.snapshot_for(restored.session)
guard = repo.control_change_guard(table:restored.table, game:game, session:current.session, player:dummy)
restored.as('Alice') do
  restored.transports['Alice'].replace_game_player(restored.table, session_id:repo.session_id(current.session),
    player:dummy, control_guard:guard)
end
changed = restored.replay('Alice')
dummy_bot = changed.state[:seats][changed.state[:seat_to_play]]
assert(GameRoomParticipants.bot?(dummy_bot), 'ordinary dummy did not become a named bot')
assert(changed.current_player == declarer, 'replacement dummy stole control from declarer')
assert(changed.state[:hands][dummy_bot] == before.state[:hands][dummy], 'replacing dummy changed its cards')
assert(changed.history.map(&:to_h) == before.history.map(&:to_h), 'dummy replacement rewrote historical authors')
assert(game.legal_actions(changed, dummy_bot).empty?, 'bot dummy gained a second independent turn')

# Replace declarer as well, then hand the table to a non-playing observer.
# The existing bot coordinator must choose from dummy, not its own hand.
current = repo.snapshot_for(restored.session)
guard = repo.control_change_guard(table:restored.table, game:game, session:current.session, player:declarer)
restored.as('Alice') do
  restored.transports['Alice'].replace_game_player(restored.table, session_id:repo.session_id(current.session),
    player:declarer, control_guard:guard)
end
restored.add_client('Watcher')
assert(restored.join('Watcher'), 'ordinary observer could not join')
restored.as('Watcher') { restored.transports['Watcher'].set_observer(restored.table, true, actor:'Watcher') }
restored.view('Alice').transfer_ownership(restored.view('Alice').participants.find { |part| part.user == 'Watcher' })
repo = restored.repositories['Watcher']
current = restored.as('Watcher') do
  restored.transports['Watcher'].room_snapshot(restored.table)
  repo.snapshot_for(restored.session)
end
replay = game.replay(current.session, current.events, repo)
assert(GameRoomParticipants.bot?(replay.current_player), 'declarer replacement did not retain turn')
assert(replay.state[:hands][replay.current_player] == before.state[:hands][declarer], 'replacement declarer lost own cards')
context = GameRoomGames::ActionContext.new(now:Time.now.to_i, random_source:GameRoomRandom::SeededSource.new(4))
decision = GameRoomBots::Coordinator.new.decide_next(game:game, replay:replay, context:context)
assert(decision && decision.action['zone'] == 'dummy', 'declarer bot selected its own hand on dummy turn')
assert(replay.state[:hands][dummy_bot].include?(decision.action['card']), 'bot decision used a foreign hand')
status, plan = game.action_for(decision.action, replay, decision.actor, context:context)
assert(status == :ok, 'bot dummy choice rejected')
restored.as('Watcher') do
  repo.append_events(session:current.session, sequence:repo.next_sequence(current.session, current.events),
    events:plan.events, actor:decision.actor, controller:true)
end
after = restored.replay('Watcher')
assert(after.accepted_events.size == replay.accepted_events.size + 1 && after.state[:trick].size == 2,
  'new host did not publish exactly one valid dummy card')
assert(after.state[:hands][dummy_bot].size == before.state[:hands][dummy].size - 1,
  'accepted dummy play consumed the wrong hand')
assert(after.state[:hands][decision.actor].size == before.state[:hands][declarer].size,
  'declarer lost a card while playing dummy')
assert(after.history.first(before.history.size).map(&:to_h) == before.history.map(&:to_h), 'control/restore mutated historical messages')
assert(restored.users.map { |user| restored.replay(user).state }.uniq.size == 1, 'ordinary observers diverged after bot play')
puts 'PASS Bridge independent ordinary native archive at dummy turn, two named replacements, observer host, correct bot hand and immutable history'
