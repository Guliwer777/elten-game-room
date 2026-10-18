require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
D=86_400

def prepare(c,start:0,closing:0)
  public_tables=T::LocalTestTables.new(directory:File.join(c.directory,'server'),user:-> {c.user},clock:-> {c.now})
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {c.user})
  docs.on_insert=->(row){row['__insertion_time']=c.now}
  provider=Object.new
  provider.define_singleton_method(:available?){true}
  provider.define_singleton_method(:fetch){|name| name=='tournament_plan_documents' ? docs : public_tables.fetch(name)}
  make=-> {T::ServerWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},
    alert:->(text){c.alerts<<text},clock:-> {c.now},readiness_clock:-> {c.now},provider_factory:-> {provider})}
  values=params('tic_tac_toe',timezone:'UTC',registration_closes_at:closing)
  values[:draft]=values[:draft].merge('windows'=>[],'starts_at'=>start,'deadline_at'=>0)
  record=make.call.publish(**values)
  assert(record && record['status']=='confirmed',c.alerts.inspect)
  [make,provider,docs,record['evidence']['canonical_id']]
end

sandbox do |c|
  make,provider,docs,id=prepare(c)
  c.now+=13*D
  c.user='Second'
  joined=make.call.join(id)
  assert_equal('confirmed',joined['status'])
  c.now+=13*D
  assert_equal(1,make.call.load['announcements'].size)
  before=docs.insert_count
  c.now+=D
  %w[Second RealOwner].each do |name|
    c.user=name
    workspace=make.call
    assert_equal([],workspace.load['announcements'])
    assert_equal([],workspace.load['members'])
    assert_equal([],workspace.directory_on_worker['announcements'])
    assert_equal(nil,workspace.join(id),'An expired tournament still accepts a registration')
    assert_equal(:unknown_tournament,workspace.last_error.code)
    assert_equal('confirmed',workspace.reconcile(joined['id'])['status'],'Expiry invalidated confirmed registration evidence') if name=='Second'
  end
  assert_equal(before,docs.insert_count,'Retention wrote housekeeping records')
  assert_equal(0,docs.insert_count,'An unstarted tournament read match documents')
end

sandbox do |c|
  make,provider,docs,id=prepare(c)
  c.now+=13*D
  workspace=make.call
  row=workspace.load['announcements'].first
  assert_equal('confirmed',workspace.change_phase(tournament_id:id,action:'close',intent_id:'close',
    expected_generation:T::RegistrationProjection.publication_generation(row))['status'])
  c.now+=13*D
  assert_equal(1,make.call.load['announcements'].size,'An organizer change did not renew the unstarted tournament')
  c.now+=D
  assert_equal([],make.call.load['announcements'],'Closed registration with a manual start never expired')
end

sandbox do |c|
  make,provider,docs,id=prepare(c,start:150+60*D)
  c.user='Second'
  make.call.join(id)
  c.now=150+59*D
  assert_equal(1,make.call.load['announcements'].size,'Scheduled tournament disappeared before its start')
  c.now=150+90*D
  assert_equal([],make.call.load['announcements'],'Scheduled tournament did not expire after 30 days without results')
end

sandbox do |c|
  make,provider,docs,id=prepare(c)
  %w[Second Third].each{|name|c.user=name;assert_equal('confirmed',make.call.join(id)['status'])}
  c.user='RealOwner'
  workspace=make.call
  row=workspace.load['announcements'].first
  ref={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
  assert_equal('confirmed',workspace.change_phase(tournament_id:id,action:'start',intent_id:'start',
    expected_generation:T::RegistrationProjection.publication_generation(row))['status'])
  c.now+=29*D
  service=workspace.ordinary_service(publication_ref:ref,lobby:nil,games:nil,transport:nil)
  begin
    state=workspace.shared_schedule(publication_ref:ref)
    candidate=state.fetch('candidate')
    match=candidate['matches'].first
    service.confirm_forfeit(preview:service.forfeit_preview(match_id:match['match_id'],leg:match['leg'],loser:match['players'].last,expected_schedule_id:candidate['schedule_id']))
    c.now+=2*D
    assert_equal(1,make.call.load['announcements'].size,'A confirmed result did not extend retention')
    assert_equal([150+29*D],service.result_view['progress_times'])
    old=docs.rows.map(&:dup)
    # Same authenticated parts resent later are not a new sporting event.
    old.each{|part|docs.insert(part.reject{|key,_|key.start_with?('__')})}
    assert_equal([150+29*D],service.result_view['progress_times'])
    # A partial/foreign record must not refresh the deadline either.
    c.user='Intruder'
    docs.insert(old.first.reject{|key,_|key.start_with?('__')})
    c.user='RealOwner'
    c.now=150+59*D
    writes=docs.insert_count
    assert_equal([],make.call.load['announcements'])
    expired=make.call.ordinary_service(publication_ref:ref,lobby:nil,games:nil,transport:nil)
    begin
      error=assert_raises(T::Publication::Invalid){expired.open_match(match_id:match['match_id'],leg:match['leg'])}
      assert_equal(:missing_publication,error.code,'Stale match reference entered an expired tournament')
    ensure
      expired&.close
    end
    assert_equal(writes,docs.insert_count,'Expiry wrote over sporting history')
  ensure
    service.close
  end
end

sandbox do |c|
  make,provider,docs,id=prepare(c)
  c.user='Second'
  make.call.join(id)
  c.user='RealOwner'
  workspace=make.call
  row=workspace.load['announcements'].first
  ref={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
  workspace.change_phase(tournament_id:id,action:'start',intent_id:'start',expected_generation:T::RegistrationProjection.publication_generation(row))
  c.now+=29*D
  candidate=workspace.shared_schedule(publication_ref:ref)['candidate']
  service=workspace.ordinary_service(publication_ref:ref,lobby:nil,games:nil,transport:nil)
  begin
    match=candidate['matches'].first
    service.confirm_forfeit(preview:service.forfeit_preview(match_id:match['match_id'],leg:match['leg'],loser:match['players'].last,expected_schedule_id:candidate['schedule_id']))
    c.now+=300*D
    finished=make.call.load['announcements'].first
    assert(finished && finished['sporting_completed'],'Completed tournament was deleted as abandoned')
    assert(!finished['expires_at'])
    timestamps=docs.rows.map{|row|row['__insertion_time']}
    docs.rows.first.delete('__insertion_time')
    assert_equal(1,make.call.load['announcements'].size,'Incomplete result timestamps were treated as abandonment')
    docs.rows.zip(timestamps){|row,time|row['__insertion_time']=time}
    docs.on_select=-> {raise EltenLink::Error.timeout}
    assert_equal(nil,make.call.load,'Network failure was treated as empty sporting history')
  ensure
    service.close
  end
end
puts 'PASS server workspace retention: 14/30-day expiry, multi-account agreement, fresh action guards, confirmed progress, replay duplicates, completed preservation, no writes and failure safety (simulated server)'
