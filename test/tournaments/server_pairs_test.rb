require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_trial_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T = GameRoomTournaments
sandbox do |c|
  tables = T::LocalTestTables.new(directory: File.join(c.directory, 'server'), user: -> { c.user }, clock: -> { c.now })
  plans = TournamentServerPlanTableSupport::Table.new(user: -> { c.user })
  provider = Object.new
  provider.define_singleton_method(:available?) { true }
  provider.define_singleton_method(:fetch) { |name| name == 'tournament_plan_documents' ? plans : tables.fetch(name) }
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { c.alerts << m }, clock: -> { c.now }, provider_factory: -> { provider }) }
  values = params('spades', timezone: 'UTC')
  values[:draft] = values[:draft].merge('rematch' => true, 'players_per_match' => 4,
    'game_options' => GameRoomGames::CATALOG.build('spades').normalize_options({'team_size' => 2}))
  published = build.call.publish(**values)
  id = published['evidence']['canonical_id']
  row = build.call.load['announcements'].first
  ref = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
  %w[Second Third Fourth].each { |name| c.user = name; assert_equal('confirmed', build.call.join(id)['status']) }
  c.user = 'Second'
  assert_equal('confirmed', build.call.set_partner(id, 'Second', 'Third', 'self-pair')['status'])
  c.user = 'Fourth'
  stranger = build.call
  assert_equal(nil, stranger.set_partner(id, 'Second', 'RealOwner', 'forbidden-pair'))
  assert_equal(:not_organizer, stranger.last_error.code)
  c.user = 'RealOwner'
  assert_equal('confirmed', build.call.set_partner(id, 'RealOwner', 'Fourth', 'organizer-pair')['status'])
  c.now = 201
  first = build.call.shared_schedule(publication_ref: ref)
  assert_equal('confirmed', first['storage'])
  assert_equal('fixed-teams', first['candidate']['source_kind'])
  assert_equal(2, first['candidate']['matches'].size)
  assert(first['candidate']['matches'].all? { |m| m['unit_ids'].size == 2 && m['players'].size == 4 })
  c.user = 'Second'
  assert_equal(first, build.call.shared_schedule(publication_ref: ref))
  c.user = 'RealOwner'
  assert_equal('confirmed', build.call.set_partner(id, 'RealOwner', 'Third', 'change-pair-1')['status'])
  assert_equal(:incomplete_pairs, build.call.shared_schedule(publication_ref: ref)[:reason])
  assert_equal('confirmed', build.call.set_partner(id, 'Second', 'Fourth', 'change-pair-2')['status'])
  changed = build.call.shared_schedule(publication_ref: ref)
  assert_equal('confirmed', changed['storage'])
  assert(changed['candidate']['roster_generation'] != first['candidate']['roster_generation'])
  assert_equal('confirmed', build.call.remove_participant(id, 'Fourth')['status'])
  assert_equal(3, build.call.load['members'].size)
  assert_equal(:incomplete_pairs, build.call.shared_schedule(publication_ref: ref)[:reason])
  c.user = 'Third'
  assert_equal('confirmed', build.call.withdraw(id)['status'])
  c.user = 'Second'
  c.now = Time.utc(2026, 10, 16).to_i
  too_late = build.call
  assert_equal(nil, too_late.withdraw(id))
  assert_equal(:tournament_started, too_late.last_error.code)
end
puts 'PASS server pairs: self-choice, organizer changes/removal, permissions, partner release, shared team plans and withdrawal deadline'
