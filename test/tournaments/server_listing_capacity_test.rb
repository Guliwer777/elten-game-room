require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T = GameRoomTournaments

sandbox do |c|
  tables = T::LocalTestTables.new(directory: File.join(c.directory, 'server'), user: -> {c.user}, clock: -> {c.now})
  reads=Hash.new(0)
  native_read=tables.method(:select_rows)
  tables.define_singleton_method(:select_rows) do |name,**args|
    reads[name]+=1
    native_read.call(name,**args)
  end
  plans = TournamentServerPlanTableSupport::Table.new(user: -> {c.user})
  provider = Object.new
  provider.define_singleton_method(:fetch) { |name| name == 'tournament_plan_documents' ? plans : tables.fetch(name) }
  provider.define_singleton_method(:available?) { true }
  build = -> { T::ServerWorkspace.new(program:c.program, registry:GameRoomGames::CATALOG, user:-> {c.user},
    alert:->(message) {c.alerts << message}, clock:-> {c.now}, provider_factory:-> {provider}) }
  organizer = build.call
  record = organizer.publish(**params(timezone:'UTC'))
  id = record.fetch('evidence').fetch('canonical_id')
  11.times { |index| c.user="Player#{index}"; assert(build.call.join(id)) }
  c.user = 'RealOwner'
  row = organizer.load.fetch('announcements').first
  reference = {'author'=>row['__insertion_user'], 'publication_key'=>row['publication_key']}
  c.now = 201
  candidate = organizer.shared_schedule(publication_ref:reference).fetch('candidate')
  assert_equal(66, candidate.fetch('matches').size)
  reads.clear
  assert_equal(1, organizer.load.fetch('announcements').size)
  assert(reads.values.all?{|count|count<=3},"Directory repeats publication/registration reads: #{reads.inspect}")
  assert_equal(nil, organizer.last_error)
  assert(c.alerts.empty?, 'A supported larger tournament broke the directory')

  original = T::OrdinaryMatchService.instance_method(:result_view)
  T::OrdinaryMatchService.define_method(:result_view) { |**| raise T::Publication::Invalid, :incomplete_plan_document }
  listing = organizer.load
  assert_equal(1, listing.fetch('announcements').size)
  assert_equal('incomplete_plan_document', listing['announcements'].first['plan_error'])
  assert_equal(nil, organizer.last_error)
ensure
  T::OrdinaryMatchService.define_method(:result_view, original) if original
end
puts 'PASS server directory: 12 entrants / 66 matches; invalid plan is isolated without fabricated completion'
