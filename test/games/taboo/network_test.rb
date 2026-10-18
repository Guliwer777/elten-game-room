require_relative "../../support/ui"
require_relative "../../support/native_live_sessions"
class Program
  def self.server_app(**_options); end
  def self.app_runtime; nil; end
end
require_relative "../../../__app"

broker = NativeLiveSessionsBroker.new
users = %w[Moderator Alice Bob Carol Dave]
transports, repositories = {}, {}
users.each do |user|
  program = ProgramDouble.new(broker.endpoint(user))
  transports[user] = GameRoomTransport.new(program)
  repositories[user] = GameRepository.new(program, transport: transports[user], server_tables: {})
end
$game_room_test_user = 'Moderator'
master = transports.fetch('Moderator')
repo = repositories.fetch('Moderator')
lobby = LobbyRepository.new(ProgramDouble.new(broker.endpoint('Moderator')), transport: master, server_tables: {})
game = GameRoomGames::Taboo.new
table = lobby.create_table(name: 'Moderated Taboo', game: game.id, owner: 'Moderator', game_options: JSON.generate(game.normalize_options({}))).table
users.drop(1).each { |user| transports[user].join_room(table, user) }
master.set_observer(table, true, actor: 'Moderator')
players = users.drop(1)
session = repo.start_session(table: table, game: game.id, players: players, options: table['game_options'])
assert(repo.session_for_table(table)['__id'] == session['__id'], 'observer-owned game was not recognized')
users.each { |user| assert(repositories[user].session_by_id(session['__id'], table: table), "session missing for #{user}") }
# The native store authenticates the original author independently of a
# caller's stale table-owner snapshot (ownership can now be transferred).
stale_owner = table.merge('owner' => 'Attacker', '__insertion_user' => 'Attacker')
assert(repo.session_by_id(session['__id'], table: stale_owner), 'authenticated history was rejected against a stale owner')
assert(!repo.send(:valid_session_for_table?, session.merge('__authority_validated' => false), stale_owner, players: players), 'unverified foreign creator accepted')
assert(repo.session_by_id(session['__id'], table: table.merge('__id' => table['__id'] + 1)).nil?, 'foreign table accepted')
begin
  $game_room_test_user = 'Bob'
  repositories['Bob'].start_session(table: table, game: game.id, players: players, options: table['game_options'])
  raise 'non-owner created a native game through the repository'
rescue ArgumentError, EltenAPI::LiveSessions::NotOwner
  assert(repo.session_for_table(table)['__id'] == session['__id'], 'rejected start replaced the game')
ensure
  $game_room_test_user = 'Moderator'
end
raw = transports['Bob'].start_game(table: table, game: game.id, players: players, options: table['game_options'], actor: 'Bob')
# The low-level sender returns its submitted row; only authenticated stack
# projection is authoritative, on the sender as well as on every recipient.
repositories.each_value do |local|
  assert(local.session_for_table(table)['__id'] == session['__id'], 'native replay accepted a foreign game-start author')
  assert(local.session_by_id(raw['__id'], table: table).nil?, 'foreign game-start row became replayable')
end
random = Object.new
def random.roll(count:, sides:); Struct.new(:values).new(Array.new(count, 1)); end
replay = -> { game.replay(session, repo.snapshot_for(session, force_events: true).events, repo) }
screen = GameScreen.allocate
screen.instance_variable_set(:@table_owner, 'Moderator')
screen.instance_variable_set(:@game, game)
send_action = lambda do |user, action, extra = {}|
  $game_room_test_user = user
  current = replay.call
  selection = { 'action' => action, 'token' => game.token(current.state) }.merge(extra)
  actor = screen.send(:selected_action_actor, selection, current)
  now = %w[begin timeout].include?(action) ? current.state[:deadline] : current.state[:time] + 1
  context = GameRoomGames::ActionContext.new(now: now, random_source: random, table_owner: 'Moderator',
    server_random: session['__server_random'] == GameRoomServerRandom::VERSION)
  status, plan = game.action_for(selection, current, actor, context: context)
  assert(status == :ok, "#{user}/#{action}: #{status}")
  own_repo = repositories.fetch(user)
  events = own_repo.snapshot_for(session, force_events: true).events
  own_repo.append_events(session: session, events: plan.events, actor: actor, controller: actor != user, sequence: events.length + 1)
  replay.call
end
state = send_action.call('Moderator', 'deal')
assert(state.state[:phase] == :ready, 'moderator deal failed')
giver = state.current_player
send_action.call(giver, 'start')
state = send_action.call('Moderator', 'begin')
assert(state.state[:phase] == :describing, 'moderator could not start the timer')
assert(game.card_lines(state.state, 'Moderator').empty?, 'observing moderator saw the live card')
send_action.call(giver, 'correct')
state = send_action.call('Moderator', 'timeout')
assert(state.state[:phase] == :review, 'moderator could not end the timer')

# First seat is the deterministic controller actor, not a grant of authority.
forged = send_action.call(players.first, 'approve')
assert(forged.state[:phase] == :review && forged.state[:scores] == [0,0], 'non-master first seat approved the score')
state = send_action.call('Moderator', 'correct_result', 'index' => 0, 'result' => 'neutral')
entry = state.history.find { |item| item.kind == :review_correction }
assert(entry.actor == 'Moderator' && entry.text.start_with?('Moderator corrects'), 'correction named the controlled seat instead of the moderator')
state = send_action.call('Moderator', 'approve')
assert(state.state[:phase] == :ready && state.state[:completed] == 1, 'moderator approval failed')
users.each do |user|
  local = repositories[user]
  restored = game.replay(session, local.snapshot_for(session, force_events: true).events, local)
  assert(restored.state == state.state, "different replay for #{user}")
end
puts 'Taboo native transport: observer moderator, authorization, review, five-client replay: OK'
