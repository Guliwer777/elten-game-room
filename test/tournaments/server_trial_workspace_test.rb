require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_workspace'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_trial_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T = GameRoomTournaments

sandbox do |c|
  provider = T::LocalTestTables.new(directory: File.join(c.directory, 'simulated-server'), user: -> { c.user }, clock: -> { c.now })
  calls = []
  factory = -> { calls << Thread.current; provider }
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { raise 'Worker alert' unless Thread.current == c.ui_thread; c.alerts << m }, clock: -> { c.now }, provider_factory: factory) }
  owner = build.call
  assert_equal([], calls)
  assert_equal(nil, owner.publish(**params(timezone: 'UTC', rules: 'x' * 2049)))
  assert_equal(:server_trial_payload_limit, owner.last_error.code)
  assert_equal([], owner.operations)
  c.alerts.clear
  published = owner.publish(**params(timezone: 'UTC'))
  assert_equal('confirmed', published['status'])
  id = published['evidence']['canonical_id']
  assert_equal([c.user.downcase], owner.load['members'].map { |m| m['account'] })
  assert(calls.none? { |thread| thread == c.ui_thread })
  c.user = 'OtherPlayer'
  participant = build.call
  assert_equal('confirmed', participant.join(id)['status'])
  assert_equal(2, participant.load['members'].size)
  assert_equal('confirmed', participant.withdraw(id)['status'])
  assert_equal(1, participant.load['members'].size)
  assert_equal([], c.alerts)
  assert_equal(nil, owner.load)
  c.user = 'RealOwner'
  assert_equal(nil, owner.load, 'Account changes must latch even after returning')
  reopened = build.call
  assert_equal(published['id'], reopened.operations.first['id'])
  assert_equal(1, reopened.load['announcements'].size)
end
puts 'PASS separate server workspace: lazy worker composition, authenticated accounts, shared list and durable journals'

sandbox do |c|
  table = Object.new
  table.define_singleton_method(:select) { |**| raise EltenLink::Error.timeout }
  provider = Object.new
  provider.define_singleton_method(:available?) { true }
  provider.define_singleton_method(:fetch) { |_| table }
  workspace = T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG,
    user: -> { c.user }, alert: ->(m) { c.alerts << m }, provider_factory: -> { provider })
  assert_equal(nil, workspace.load)
  assert(workspace.last_error.is_a?(T::TablesGateway::ProviderFailure))
  assert(c.alerts.first.include?('No local fallback'))
  assert(!Dir.glob(File.join(c.directory, 'tournament-local-test-*')).any?)
  table.define_singleton_method(:select) { |**| raise NoMethodError, 'Programming defect' }
  assert_raises(NoMethodError) { workspace.load }
end
puts 'PASS server failure is not an empty list or local fallback; programming errors propagate'

sandbox do |c|
  provider = T::LocalTestTables.new(directory: File.join(c.directory, 'simulated-server'), user: -> { c.user }, clock: -> { c.now })
  original = provider.method(:insert_row)
  lost = true
  insert_count = 0
  provider.define_singleton_method(:insert_row) do |name, values|
    insert_count += 1
    row = original.call(name, values)
    raise EltenLink::Error.timeout if lost
    row
  end
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { c.alerts << m }, clock: -> { c.now }, provider_factory: -> { provider }) }
  workspace = build.call
  assert_equal(nil, workspace.publish(**params(timezone: 'UTC')))
  assert(workspace.last_error.is_a?(T::TablesGateway::UnconfirmedWrite))
  record = workspace.operations.first
  lost = false
  reopened = build.call
  assert_equal('confirmed', reopened.reconcile(record['id'])['status'])
  assert_equal(2, insert_count, 'Exactly one publication and one automatic creator registration')
  assert_equal(1, reopened.load['announcements'].size)
end
puts 'PASS lost server acknowledgement reconciles without repeating publication and enrolls creator once'

sandbox do |c|
  provider = T::LocalTestTables.new(directory: File.join(c.directory, 'simulated-server'), user: -> { c.user }, clock: -> { c.now })
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { c.alerts << m }, clock: -> { c.now }, provider_factory: -> { provider }) }
  organizer = build.call
  values = params(timezone: 'UTC')
  values[:draft] = values[:draft].merge('rematch' => true)
  record = organizer.publish(**values)
  id = record['evidence']['canonical_id']
  row = organizer.load['announcements'].find { |r| r['__id'] == id }
  reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
  assert_equal(:registration_open, organizer.schedule_candidate(publication_ref: reference)[:reason])
  %w[Second Third Fourth].each { |name| c.user = name; assert_equal('confirmed', build.call.join(id)['status']) }
  c.now = 201
  visitor = build.call
  first = visitor.schedule_candidate(publication_ref: reference)
  assert_equal(12, first['matches'].size)
  assert_equal(6, first['matches'].count { |m| m['leg'] == 2 })
  assert_equal(false, first['start_allowed'])
  c.user = 'RealOwner'
  fresh = build.call.schedule_candidate(publication_ref: reference)
  assert_equal(first, fresh, 'Same observed roster produces the same schedule for organizer and participant')
  unrelated = row.slice(*T::Publication::COLUMNS).merge('publication_key' => 'unrelated-broken', 'schema_version' => 99)
  provider.fetch('tournament_announcements').insert(unrelated)
  assert_equal(first, build.call.schedule_candidate(publication_ref: reference), 'Unrelated invalid fixture must not block selected tournament')
  provider.fetch('tournament_registrations').insert({'tournament_id' => id, 'operation_key' => 'bad-selected-operation', 'kind' => 'invalid'})
  assert_equal(:unresolved_source_diagnostics, build.call.schedule_candidate(publication_ref: reference)[:reason], 'Selected diagnostics must never be discarded')
  assert_equal([], c.alerts)
  context = Object.new
  context.define_singleton_method(:current?) { |_| false }
  assert_equal(nil, build.call.schedule_candidate(publication_ref: reference, context: context, lease: Object.new))
end
puts 'PASS automatic read-only server schedule: deadline, four accounts, return matches, cold participant/organizer agreement and stale-view refusal'

sandbox do |c|
  provider = T::LocalTestTables.new(directory: File.join(c.directory, 'simulated-server'), user: -> { c.user }, clock: -> { c.now })
  build = -> { T::ServerTrialWorkspace.new(program: c.program, registry: GameRoomGames::CATALOG, user: -> { c.user },
    alert: ->(m) { c.alerts << m }, clock: -> { c.now }, provider_factory: -> { provider }) }
  organizer = build.call
  values = params(timezone: 'UTC')
  values[:draft] = values[:draft].merge('format' => 'groups_knockout', 'group_advancement' => 'automatic_compact_groups_v2', 'rematch' => true)
  record = organizer.publish(**values)
  id = record['evidence']['canonical_id']
  row = organizer.load['announcements'].find { |r| r['__id'] == id }
  %w[Second Third Fourth Fifth Sixth].each { |name| c.user = name; assert_equal('confirmed', build.call.join(id)['status']) }
  c.now = 201
  candidate = build.call.schedule_candidate(publication_ref: {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']})
  assert_equal([3, 3], candidate['groups'].map { |g| g['units'].size })
  assert_equal(12, candidate['matches'].size)
  assert_equal(candidate['matches'].map { |m| m['match_id'] }.sort, candidate['groups'].flat_map { |g| g['matches'] }.sort)
  assert_equal([], c.alerts)
end
puts 'PASS server groups: six registered accounts, two groups of three and complete return-match coverage'
