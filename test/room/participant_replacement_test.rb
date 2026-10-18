require_relative "../support/native_room_harness"
require_relative "../../games/uno"
require_relative "../../games/tic_tac_toe"
require_relative "../../games/spades"

h = NativeRoomHarness.new(game: GameRoomGames::Uno.new, users: %w[Alice Bob])
h.start
h.add_client('Watcher')
h.join('Watcher')
h.as('Alice') { h.transports['Alice'].set_observer(h.table, true, actor: 'Alice', subject: 'Watcher') }
repo = h.repositories['Alice']
context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::SeededSource.new(72),
  server_random: h.session['__server_random'] == GameRoomServerRandom::VERSION)
before = h.replay('Alice')
status, plan = h.game.action_for({'kind' => 'command', 'action' => 'deal'}, before, 'Alice', context: context)
assert(status == :ok, 'The initial deal was not prepared')
h.as('Alice') { repo.append_events(session: h.session, sequence: 0, events: plan.events, actor: 'Alice') }
before = h.replay('Alice')
original = h.events('Alice').map(&:dup)
hands = Marshal.load(Marshal.dump(before.state[:hands]))
history = before.history.map(&:to_h)

h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: 'Bob') }
snapshot = repo.snapshot_for(h.session)
bot = snapshot.session['__players'].last
assert(GameRoomParticipants.bot?(bot), 'No actual bot identity was added')
assert(snapshot.session['__controllers'].empty?, 'Human is still controlled under their own name')
after = h.game.replay(snapshot.session, snapshot.events, repo)
assert(after.players == ['Alice', bot], 'Replay retained the former player')
assert(after.state[:hands][bot] == hands['Bob'], 'The new bot lost the inherited hand')
assert(!after.state[:hands].key?('Bob'), 'The former player still owns a hand')
assert(after.history.map(&:to_h) == history, 'Replacement rewrote the old history')
assert(snapshot.events == original, 'Replacement changed the stored events')
room = h.as('Alice') { h.transports['Alice'].room_snapshot(h.table) }
assert(room[:bots] == [bot], 'Room did not contain the named replacement bot')
assert(room[:observers].include?('Bob'), 'Replaced human did not become an observer')

h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: bot, replacement: 'Watcher') }
snapshot = repo.snapshot_for(h.session)
after = h.game.replay(snapshot.session, snapshot.events, repo)
assert(after.players == %w[Alice Watcher], 'Spectator did not physically replace the bot')
assert(after.state[:hands]['Watcher'] == hands['Bob'], 'Spectator did not inherit the bot hand')
assert(after.history.map(&:to_h) == history, 'Second replacement rewrote history')

# Existing archives can contain older occupied-place exchanges. They remain
# readable, but a new request must not perform one (including a stale dialog).
begin
  h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: 'Alice', replacement: 'Watcher') }
  raise 'A new occupied-place exchange was accepted'
rescue GameRoomNetworkErrors::GamePaused
end
h.as('Alice') { h.transports['Alice'].instance_variable_get(:@live_store).send(:publish_control, h.table['__id'], h.session['__id'], {}, players: %w[Watcher Alice]) }
snapshot = repo.snapshot_for(h.session)
after = h.game.replay(snapshot.session, snapshot.events, repo)
assert(after.players == %w[Watcher Alice], 'Playing humans were not swapped atomically')
assert(after.state[:hands]['Watcher'] == hands['Alice'] && after.state[:hands]['Alice'] == hands['Bob'], 'Swap did not exchange both hands')
assert(after.history.map(&:to_h) == history, 'Swap rewrote historical names')
assert(after.accepted_events.length == original.length, 'A previous event became invalid')
assert(repo.snapshot_for(h.session).session['__players'] == %w[Watcher Alice], 'An old snapshot undid the current roster')
room = h.as('Alice') { h.transports['Alice'].room_snapshot(h.table) }
assert(!room[:observers].include?('Watcher') && !room[:observers].include?('Alice'), 'Swapping two players made one an observer')
# An observer cannot be the source anymore; returning them replaces a player.
begin
  h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: 'Bob', replacement: 'Watcher') }
  raise 'Observer accepted as a replacement source'
rescue GameRoomNetworkErrors::GamePaused
end
h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: 'Watcher', replacement: 'Bob') }
snapshot = repo.snapshot_for(h.session)
room = h.as('Alice') { h.transports['Alice'].room_snapshot(h.table) }
assert(snapshot.session['__players'] == %w[Bob Alice], 'Observer-first operation did not swap into the match')
assert(room[:observers].include?('Watcher') && !room[:observers].include?('Bob'), 'Observer-first operation failed to exchange roles')
assert(room[:bots].empty?, 'Replaced bot remained at the table')

# The same direct exchange also works when the owner selects the player first.
h.as('Alice') { h.transports['Alice'].replace_game_player(h.table, session_id: repo.session_id(h.session), player: 'Bob', replacement: 'Watcher') }
room = h.as('Alice') { h.transports['Alice'].room_snapshot(h.table) }
assert(room[:observers].include?('Bob') && !room[:observers].include?('Watcher'), 'Player-first operation failed to exchange roles')
assert(h.replay('Watcher').state[:hands]['Watcher'] == hands['Alice'], 'Incoming observer received a different hand')
h.assert_converged('Repeated direct player/observer swaps', expected_count: original.length)
stale = snapshot.session
begin
  h.as('Bob') { h.repositories['Bob'].append_events(session: stale, sequence: 1,
    events: [GameRoomGames::EventCommand.new(action: 'draw', value: '')], actor: 'Bob') }
  raise 'The replaced observer could still submit an action'
rescue GameRoomNetworkErrors::GamePaused, ArgumentError
end
assert(h.events('Alice') == original, 'Rejected observer action changed the log')

# A manual team arrangement belongs to places, not to the old occupants.
game = GameRoomGames::Spades.new
players = %w[Alice Bob Carol Dave]
options = game.with_team_assignment(game.default_options.merge('team_size' => 2), players: players, seats: [0, 0, 1, 1])
teams = NativeRoomHarness.new(game: game, users: players, options: options)
teams.start
teams.add_client('Watcher')
teams.join('Watcher')
teams.as('Alice') { teams.transports['Alice'].set_observer(teams.table, true, actor: 'Alice', subject: 'Watcher') }
teams.as('Alice') { teams.transports['Alice'].replace_game_player(teams.table, session_id: teams.session['__id'], player: 'Bob', replacement: 'Watcher') }
state = teams.replay('Watcher')
assignment = game.team_assignment(state.state[:options], players: state.players)
assert(assignment.members_for(0) == %w[Alice Watcher], 'Incoming observer did not inherit the team')
teams.as('Alice') { teams.transports['Alice'].instance_variable_get(:@live_store).send(:publish_control, teams.table['__id'], teams.session['__id'], {}, players: %w[Alice Carol Watcher Dave]) }
state = teams.replay('Carol')
assignment = game.team_assignment(state.state[:options], players: state.players)
assert(assignment.members_for(0) == %w[Alice Carol] && assignment.members_for(1) == %w[Watcher Dave], 'Players did not exchange their team places')
room = teams.as('Alice') { teams.transports['Alice'].room_snapshot(teams.table) }
prepared = game.prepared_team_assignment(JSON.parse(room[:table]['game_options']), players: state.players)
assert(prepared && prepared.members_for(0) == %w[Alice Carol], 'Next-match team settings kept the previous people')
teams.assert_converged('Team swap')
puts 'Actual participant replacement: human -> named bot -> spectator, human swap, hands and immutable history: OK'
