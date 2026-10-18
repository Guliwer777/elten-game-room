require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T = GameRoomTournaments

sandbox do |c|
  tables=T::LocalTestTables.new(directory:File.join(c.directory,'server'),user:-> {c.user},clock:-> {c.now})
  reads=[]
  native=tables.method(:select_rows)
  tables.define_singleton_method(:select_rows) do |name,**args|
    reads << [name,args]
    native.call(name,**args)
  end
  plans=TournamentServerPlanTableSupport::Table.new(user:-> {c.user})
  native_plans=plans.method(:select)
  plans.define_singleton_method(:select) do |**args|
    reads << ['plans',args]
    native_plans.call(**args)
  end
  provider=Object.new
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? plans : tables.fetch(name)}
  provider.define_singleton_method(:available?){true}
  build=-> {T::ServerWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},
    alert:->(message){c.alerts<<message},clock:-> {c.now},provider_factory:-> {provider})}
  organizer=build.call
  values=params(timezone:'UTC')
  values[:draft]=values[:draft].merge('rematch'=>true)
  id=organizer.publish(**values).fetch('evidence').fetch('canonical_id')
  c.user='Second'
  assert(build.call.join(id))
  c.user='RealOwner'
  publication=organizer.load.fetch('announcements').first
  reference={'author'=>publication['__insertion_user'],'publication_key'=>publication['publication_key']}
  c.now=201
  reads.clear
  inserted=plans.insert_count
  display=organizer.schedule_overview(publication_ref:reference,include_match_status:true)
  assert_equal('observed',display.fetch('storage'))
  assert_equal(inserted,plans.insert_count,'Opening a display wrote a redundant observed plan')
  initial_display_reads=reads.size
  organizer.shared_schedule(publication_ref:reference)
  service=organizer.ordinary_service(publication_ref:reference,lobby:nil,games:nil,transport:nil)
  reads.clear
  plan=organizer.shared_schedule(publication_ref:reference)
  view=service.result_view(include_match_status:true)
  separate_count=reads.size
  reads.clear
  tasks=0
  combined=nil
  task_hooks(before:-> {tasks+=1}) do
    combined=organizer.shared_schedule(publication_ref:reference,include_results:true,include_match_status:true)
  end
  assert_equal(1,tasks,'The overview launched more than one worker operation')
  assert_equal(plan.merge('results'=>view),combined,'Combining reads changed the schedule/results')
  assert(reads.size<separate_count,"No reduction in reads: #{reads.size} vs #{separate_count}")
  combined_count=reads.size
  assert(combined.frozen? && combined['results'].frozen?,'UI received mutable shared data')
  reads.clear
  readonly=organizer.schedule_overview(publication_ref:reference,include_match_status:true)
  assert_equal(combined.merge('storage'=>'observed'),readonly,'Read-only display changed a plan or its results')
  assert(reads.size<combined_count,'Read-only display still reconciles a persisted observed plan')
  match=combined['candidate']['matches'].first
  service.confirm_forfeit(preview:service.forfeit_preview(match_id:match['match_id'],leg:match['leg'],loser:match['players'].last,
    expected_schedule_id:combined['candidate']['schedule_id']))
  reads.clear
  updated=organizer.schedule_overview(publication_ref:reference,include_match_status:true)
  assert_equal(1,updated.fetch('results').fetch('results').size,'Refresh reused pre-write results')
  assert(!reads.empty?,'A cache escaped its operation')
  plans.on_select=-> {raise IOError,'Read failed'}
  assert_equal(nil,organizer.schedule_overview(publication_ref:reference))
  plans.on_select=nil
  assert(organizer.last_error.is_a?(IOError),'A failed result read was hidden')
  puts "PASS combined overview: #{separate_count} -> #{combined_count} reads; one task, same plan/results, fresh result after forfeit and failed-read clearing"
  puts "PASS read-only initial display: #{initial_display_reads} reads, zero plan writes"
ensure
  service&.close
end
