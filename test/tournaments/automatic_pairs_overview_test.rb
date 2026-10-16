require_relative '../support/tournament_individual_ui'
I = TournamentIndividualUI
T = GameRoomTournaments
include GameRoomTest::Assertions
state = I.fixture(names: %w[Alpha Beta Gamma Delta], game: 'spades', game_options: {'team_size' => 2}, players_per_match: 4)
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
owner = -> { I::F::OWNER }
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG, user: owner,
  actor: 'Organizator', alert: ->(m) { raise m }, clock: -> { state[:now] })
id = workspace.load['announcements'].first['__id']
workspace.set_partner(id, 'alpha', 'beta', 'first-pair')
workspace.set_partner(id, 'gamma', 'delta', 'second-pair')
entry = T::EntryContext.new(program: state[:program], runtime: state[:program].class.app_runtime, owner_reader: owner,
  actor: 'Organizator', account_events: session.actor_events)
args = {publication_ref: state[:reference], context: entry, lease: entry.capture, session: session}
result = workspace.tournament_overview(**args)
assert_equal(:confirmed, result[:state])
assert_equal(2, result[:rows].first['record']['evidence']['plan']['matches'].size)
dispatch_path = File.join(state[:plans], 'fixed-teams-v1/execution-ft2-v1/state.json')
dispatch_state = JSON.parse(File.read(dispatch_path))
intent = result[:rows].first['record']['preview']['intent_id']
assert_equal(3, dispatch_state['dispatch']['policies'].fetch(intent)['max_tables'])
connection = workspace.fixed_team_connection(context: entry, lease: entry.capture, session: session)
begin
  connection.plan_dispatch_configure(intent_id: intent, max_tables: 2)
ensure
  connection.close
end
assert_equal(result[:rows], workspace.tournament_overview(**args)[:rows])
assert_equal(2, JSON.parse(File.read(dispatch_path))['dispatch']['policies'].fetch(intent)['max_tables'])
workspace.set_partner(id, 'alpha', 'gamma', 'replace-pair')
assert_equal(:incomplete_pairs, workspace.tournament_overview(**args)[:reason])
workspace.set_partner(id, 'beta', 'delta', 'complete-new-pairs')
updated = workspace.tournament_overview(**args)
assert_equal(:confirmed, updated[:state], updated.inspect)
entry.close
session.close
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS automatic paired matches, repeat opening and organizer corrections'
