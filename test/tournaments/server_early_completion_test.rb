require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_trial_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
sandbox do |c|
  tables=T::LocalTestTables.new(directory:File.join(c.directory,'server'),user:-> {c.user},clock:-> {c.now})
  plans=TournamentServerPlanTableSupport::Table.new(user:-> {c.user})
  plans.on_insert=->(row){row['__insertion_time']=c.now}
  provider=Object.new
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? plans : tables.fetch(name)}
  provider.define_singleton_method(:available?){true}
  build=-> {T::ServerTrialWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},alert:->(message){c.alerts<<message},clock:-> {c.now},provider_factory:-> {provider})}
  organizer=build.call
  values=params(timezone:'UTC')
  values[:draft]=values[:draft].merge('rematch'=>true)
  record=organizer.publish(**values)
  id=record['evidence']['canonical_id']
  c.user='Second';build.call.join(id)
  c.user='RealOwner';c.now=201
  row=organizer.load['announcements'].first
  ref={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
  candidate=organizer.shared_schedule(publication_ref:ref)['candidate']
  service=organizer.ordinary_service(publication_ref:ref,lobby:nil,games:nil,transport:nil)
  candidate['matches'].each_with_index do |match,index|
    assert(organizer.load['announcements'].none?{|item|item['sporting_completed']},'Partial schedule marked completed')
    c.now+=1
    service.award_forfeit(match_id:match['match_id'],leg:match['leg'],winner:match['players'].first,expected_schedule_id:candidate['schedule_id'])
  end
  complete=organizer.load['announcements'].first
  assert_equal(true,complete['sporting_completed'])
  assert_equal(c.now,complete['sporting_completed_at'])
  assert_equal(:completed,T::TournamentLifecycle.classify(complete,now:c.now)[:state])
  before=plans.insert_count
  c.user='Second';c.path=File.join(c.directory,'cold-second')
  assert_equal(complete,build.call.load['announcements'].first,'Second client did not see early completion')
  assert_equal(before,plans.insert_count,'List completion read wrote server documents')
  assert_equal([],c.alerts)
  service.close
end
puts 'PASS early completion: return leg required, authenticated shared results, real server receipt time, cold second client, read-only list projection'
