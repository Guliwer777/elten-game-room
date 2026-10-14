require_relative '../support/tournament_individual_ui'
I = TournamentIndividualUI
T = GameRoomTournaments
include GameRoomTest::Assertions
state = I.fixture(names: %w[Alpha Beta Gamma Delta])
owner = -> { I::F::OWNER }
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
  user: owner, actor: 'Organizator', alert: ->(m) { raise m }, clock: -> { state[:now] })
entry = T::EntryContext.new(program: state[:program], runtime: state[:program].class.app_runtime,
  owner_reader: owner, actor: 'Organizator', account_events: session.actor_events)
args = {publication_ref: state[:reference], context: entry, lease: entry.capture, session: session}
before = workspace.tournament_overview(**args)
assert_equal(12, before[:rows].first['record']['evidence']['plan']['matches'].size)
id = workspace.load['announcements'].first['__id']
assert_equal('confirmed', workspace.remove_participant(id, 'Delta')['status'])
after = workspace.tournament_overview(**args)
assert_equal(:confirmed, after[:state])
assert_equal(1, after[:rows].size)
assert_equal(6, after[:rows].first['record']['evidence']['plan']['matches'].size)
assert(after[:rows].first['record']['evidence']['plan']['matches'].none? { |m| m['players'].any? { |p| p['account'] == 'delta' } }, 'Removed participant remains in rebuilt fixtures')
assert_equal(after[:rows], workspace.tournament_overview(**args)[:rows])
entry.close
session.close
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS participant removal rebuilds current overview without deleting old plan history'
