# encoding: UTF-8
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_readiness_session'
require_relative '../../lib/tournaments/match_entry'
require_relative '../../lib/game_room_background'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('d2b-adoption-',ENV.fetch('TMPDIR')) do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  session=T::LocalReadinessSession.new;session.choose_actor('Alicja')
  account='RealOwner'
  workspace=T::LocalWorkspace.new(program:program,registry:GameRoomGames::CATALOG,user:-> {account},actor:'Alicja',
    alert:->(message) {raise message},readiness_session:session,clock:-> {201})
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:-> {account},account_events:session.actor_events)
  controller=T::MatchEntry.new(workspace:workspace,context:entry)
  match=controller.refresh[:matches].first
  original=T::LocalReadinessConnection.method(:new)
  T::LocalReadinessConnection.define_singleton_method(:new) do |**options|
    value=original.call(**options)
    account='OtherOwner'
    value
  end
  work=GameRoomBackground::Work.new(runtime:program.class.app_runtime)
  begin
    work.start {controller.readiness(action: :inspect,match_id:match['match_id'])}
    wait_background_work(work)
    result,error=work.take
    assert(error.is_a?(T::TablesGateway::ContextChanged),'Nie odrzucono zmiany ownera po kompozycji')
  ensure
    T::LocalReadinessConnection.define_singleton_method(:new,original)
    controller.close;work.close;session.close
  end
  assert_equal(0,program.managed_resources.size)
  assert_equal(0,program.class.app_runtime.managed_resources.size)
  assert_equal(0,session.actor_events.listener_count)
  assert_equal(0,session.backend_events.listener_count)
end
puts 'PASS nieprzejęta kompozycja po zmianie ownera: zero osieroconych Registry/subskrypcji'
