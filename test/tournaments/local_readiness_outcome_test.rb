# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_readiness_session'
require_relative '../../lib/tournaments/match_entry'
require_relative '../../lib/game_room_background'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('d2b-effect-') do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  session=T::LocalReadinessSession.new
  session.choose_actor('Alicja')
  workspace=T::LocalWorkspace.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'RealOwner'},actor:'Alicja',
    alert:->(message) {raise message},readiness_session:session,clock:-> {201})
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:-> {'RealOwner'},account_events:session.actor_events)
  controller=T::MatchEntry.new(workspace:workspace,context:entry)
  match=controller.refresh[:matches].first
  work=GameRoomBackground::Work.new(runtime:program.class.app_runtime)
  call=lambda do |action,**options|
    work.start {controller.readiness(action:action,match_id:match['match_id'],**options)}
    wait_background_work(work)
    result,error=work.take
    raise error if error
    result
  end
  begin
    prepared=call.call(:prepare)
    call.call(:accept,prepared:prepared[:candidate])
    backend=controller.instance_variable_get(:@readiness_connection).instance_variable_get(:@backend)
    store,plans=backend.method(:store),backend.method(:plans)
    fail_after_store=false
    backend.define_singleton_method(:store) do |**options|
      result=store.call(**options)
      fail_after_store=true
      result
    end
    backend.define_singleton_method(:plans) do
      raise T::ReadinessContract::PortUnavailable,'Awaria odświeżenia po potwierdzonym zapisie' if fail_after_store
      plans.call
    end
    result=call.call(:declare,availability:'ready',expected_revision:0)
    assert_equal(:unknown,result[:state])
    assert(result[:operation] && result[:operation][:operation_id],'Utracono znany UUID po awarii odświeżenia')
    assert_equal(:confirmed,result[:operation][:state])
    fail_after_store=false
    reread=call.call(:inspect)
    assert_equal(result[:operation][:operation_id],reread[:records].first['operation']['operation_id'])
    assert_equal('ready',reread[:current]['state'])
  ensure
    controller.close;work.close;session.close
  end
end
puts 'PASS UUID i potwierdzony wynik zachowane przy późniejszej awarii odświeżenia'
