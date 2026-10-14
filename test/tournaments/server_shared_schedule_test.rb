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
  tables = T::LocalTestTables.new(directory: File.join(c.directory, 'simulated-server'), user: -> { c.user }, clock: -> { c.now })
  plans = TournamentServerPlanTableSupport::Table.new(user: -> { c.user })
  provider = Object.new
  provider.define_singleton_method(:available?) { true }
  provider.define_singleton_method(:fetch) { |name| name == 'tournament_plan_documents' ? plans : tables.fetch(name) }
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { c.alerts << m }, clock: -> { c.now }, provider_factory: -> { provider }) }
  organizer = build.call
  values = params(timezone: 'UTC')
  values[:draft] = values[:draft].merge('rematch' => true)
  record = organizer.publish(**values)
  id = record['evidence']['canonical_id']
  row = organizer.load['announcements'].first
  reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
  assert_equal(:registration_open, organizer.shared_schedule(publication_ref: reference)[:reason])
  assert_equal(0, plans.insert_count)
  %w[Second Third Fourth].each { |name| c.user = name; build.call.join(id) }
  c.now = 201
  participant = build.call
  missing = participant.shared_schedule(publication_ref: reference)
  assert_equal('missing', missing['storage'])
  assert_equal(0, plans.insert_count, 'Participant must not create the plan')
  c.user = 'RealOwner'
  stored = build.call.shared_schedule(publication_ref: reference)
  assert_equal('confirmed', stored['storage'])
  assert_equal(12, stored['candidate']['matches'].size)
  assert_equal(false, stored['candidate']['start_allowed'])
  assert_equal(false, stored['candidate'].key?('observed_at'))
  count = plans.insert_count
  operation = organizer.operations.find { |entry| entry['kind'] == 'plan_document' }
  assert_equal('confirmed', operation['status'])
  assert_equal('confirmed', organizer.reconcile(operation['id'])['status'])
  assert_equal(count, plans.insert_count, 'Operations only reconciles; it never inserts')
  c.now = 205
  c.user = 'Second'
  # Different local journal directory models a separate client installation.
  c.path = File.join(c.directory, 'second-client')
  assert_equal(stored, build.call.shared_schedule(publication_ref: reference))
  assert_equal(count, plans.insert_count)
  c.user = 'RealOwner'
  assert_equal(stored, build.call.shared_schedule(publication_ref: reference))
  assert_equal(count, plans.insert_count, 'Organizer on another client reuses existing rows')
  # A legitimate organizer removal changes generation; never adopt the old plan.
  tables.fetch('tournament_registrations').insert({'tournament_id' => id, 'operation_key' => 'remove-second', 'kind' => 'removal', 'account' => 'second'})
  next_source = build.call.schedule_candidate(publication_ref: reference)
  assert_equal(3, next_source['roster'].size)
  next_count = T::ServerPlanDocument.encode(next_source.reject { |k, _| k == 'observed_at' }, anchor: {
    'operation_key' => 'a'*64, 'tournament_id' => id, 'publication_digest' => next_source['publication_digest'], 'roster_generation' => next_source['roster_generation']}).size
  plans.on_insert = ->(_) { raise EltenLink::Error.timeout if plans.insert_count == count + next_count }
  uncertain = build.call
  assert_equal(nil, uncertain.shared_schedule(publication_ref: reference))
  pending = uncertain.operations.select { |entry| entry['kind'] == 'plan_document' && entry['status'] == 'attempted' }.first
  assert(pending, 'Uncertain plan must be visible in Operations')
  plans.on_insert = nil
  assert_equal('confirmed', build.call.reconcile(pending['id'])['status'])
  recovered = build.call.shared_schedule(publication_ref: reference)
  assert_equal('confirmed', recovered['storage'])
  assert_equal(6, recovered['candidate']['matches'].size)
  assert_equal(count + next_count, plans.insert_count, 'Lost acknowledgement must not cause resend')
  # Truncated storage remains unconfirmed even on a client without the journal.
  key = plans.rows.last['operation_key']
  plans.rows.delete_at(plans.rows.index { |r| r['operation_key'] == key && r['part_index'] == 1 })
  c.path = File.join(c.directory, 'third-client')
  assert_equal(nil, build.call.shared_schedule(publication_ref: reference))
  assert_equal(count + next_count, plans.insert_count, 'A partial remote document never authorizes resending')
  assert(!Dir.glob(File.join(c.directory, 'tournament-local-test-*')).any?)
end
puts 'PASS server shared schedule: organizer-only write, participant/cold-client read, changing clocks, current roster, lost acknowledgement and partial-write refusal'
