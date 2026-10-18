# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_readiness_session'
require_relative '../../lib/tournaments/match_entry'
require_relative '../../lib/game_room_background'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('d2b-access-') do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  session=T::LocalReadinessSession.new
  session.choose_actor('Alicja')
  assert(T::LocalWorkspace.instance_methods.include?(:readiness_connection),'Brak osiągalnej kompozycji Workspace K03')
  workspace=T::LocalWorkspace.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'RealOwner'},actor:'Alicja',
    alert:->(message) {raise message},readiness_session:session,clock:-> {201})
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:-> {'RealOwner'},account_events:session.actor_events)
  controller=T::MatchEntry.new(workspace:workspace,context:entry)
  view=controller.refresh
  match=view[:matches].first
  work=GameRoomBackground::Work.new(runtime:program.class.app_runtime)
  call=lambda do |action,**options|
    work.start { controller.readiness(action:action,match_id:match['match_id'],**options) }
    wait_background_work(work)
    result,error=work.take
    raise error if error
    result
  end
  begin
    before=call.call(:inspect)
    assert_equal(:local_plan_required,before[:state])
    prepared=call.call(:prepare)
    assert_equal(view[:candidate]['roster'],prepared[:candidate].to_h['roster'])
    assert_equal(:local_plan_required,call.call(:inspect)[:state])
    accepted=call.call(:accept,prepared:prepared[:candidate])
    assert_equal('unknown',accepted[:current]['state'])
    ready=call.call(:declare,availability:'ready',expected_revision:0)
    assert_equal(:confirmed,ready[:operation][:state])
    assert_equal('ready',ready[:current]['state'])
    withdrawn=call.call(:declare,availability:'withdrawn',expected_revision:1)
    assert_equal(:confirmed,withdrawn[:operation][:state])
    assert_equal('withdrawn',withdrawn[:current]['state'])
    assert_equal(2,withdrawn[:records].size)
    old=call.call(:reconcile,target:withdrawn[:target],operation_id:ready[:operation][:operation_id])
    assert_equal('ready',old[:operation][:receipt]['result']['state'])
    assert_equal('withdrawn',old[:current]['state'])
    assert_equal(:context_unavailable,controller.propose_now)
  ensure
    controller.close
    work.close
    session.close
  end
  assert_equal(0,program.managed_resources.size)
  assert_equal(0,program.class.app_runtime.managed_resources.size)
end
puts 'PASS realny Workspace/Work → osobne prepare/accept → ready/withdrawn/readback'
