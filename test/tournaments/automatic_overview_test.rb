require_relative '../support/tournament_individual_ui'
I = TournamentIndividualUI
T = GameRoomTournaments
include GameRoomTest::Assertions
groups = ARGV.include?('--groups') || ARGV.include?('--legacy-groups')
state = I.fixture(names: %w[Alpha Beta Gamma Delta], format: groups ? 'groups_knockout' : 'round_robin',
  group_advancement: ARGV.include?('--groups') ? T::GroupAdvancement::AUTOMATIC : nil)
match_count = groups ? 4 : 12
owner = -> { I::F::OWNER }
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
  user: owner, actor: 'Organizator', alert: ->(message) { raise message }, clock: -> { state[:now] })
entry = T::EntryContext.new(program: state[:program], runtime: state[:program].class.app_runtime,
  owner_reader: owner, actor: 'Organizator', account_events: session.actor_events)
args = {publication_ref: state[:reference], context: entry, lease: entry.capture, session: session}
first = workspace.tournament_overview(**args)
assert_equal(:confirmed, first[:state])
assert_equal(1, first[:rows].size)
record = first[:rows].first['record']
assert_equal(match_count, record['evidence']['plan']['matches'].size)
assert_equal(4, first[:rows].first['progress']['standings'].size)
second = workspace.tournament_overview(**args)
assert_equal(record, second[:rows].first['record'])
assert_equal(1, I.with_connection(state, 'Alpha') { |connection| connection.tournament_catalog(publication_ref: state[:reference]).size })
assert_equal(match_count, I.with_connection(state, 'Observer') { |connection| connection.tournament_catalog(publication_ref: state[:reference]).first['progress']['matches'].size })
assert_equal(2, record['preview']['source']['candidate']['groups'].size) if groups
puts 'PASS four players: 12 automatic return matches, standings and stable repeated overview'
entry.close
session.close
state[:program].finalize
state[:program].class.app_runtime.close
