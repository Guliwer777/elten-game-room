# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
T=GameRoomTournaments
H=TournamentLocalHubTest
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
[:back,:runtime,:actor_aba,:backend_aba].each do |mode|
  GameRoomTest::TemporaryDirectory.create('d2b-close-') do |directory|
    program=TournamentMatchEntryTest.prepare(directory)
    runtime=program.class.app_runtime
    session=T::LocalReadinessSession.new
    session.choose_actor('Alicja')
    owner=T::LocalTestDialogs::Owner.new(-> {'RealOwner'},->(message) {raise message})
    workspace=T::LocalWorkspace.new(program:program,registry:GameRoomGames::CATALOG,user:owner.method(:current),
      actor:'Alicja',alert:->(message) {raise message},clock:-> {201},readiness_session:session)
    entry=T::EntryContext.new(program:program,runtime:runtime,owner_reader:owner.method(:current),account_events:session.actor_events)
    controller=T::MatchEntry.new(workspace:workspace,context:entry)
    view=controller.refresh
    id=view[:matches].first['match_id']
    preparation=GameRoomBackground::Work.new(runtime:runtime)
    preparation.start {controller.readiness(action: :prepare,match_id:id)}
    wait_background_work(preparation)
    result,error=preparation.take;raise error if error
    preparation.start {controller.readiness(action: :accept,match_id:id,prepared:result[:candidate])}
    wait_background_work(preparation)
    result,error=preparation.take;raise error if error
    preparation.close
    screen=T::MatchEntryScreen.new(program:program,workspace:workspace,owner:owner,controller:controller)
    backend=controller.instance_variable_get(:@readiness_connection).instance_variable_get(:@backend)
    store=backend.method(:store)
    entered,release,completed=Queue.new,Queue.new,Queue.new
    backend.define_singleton_method(:store) do |**options|
      entered << Thread.current
      release.pop
      begin
        store.call(**options)
      ensure
        completed << Thread.current
      end
    end
    driver=TournamentNativeDriver.new
    worker=nil
    speech=nil
    driver.step('My tournaments') do |form|
      H.button(form,'Check status').press
      work=screen.instance_variable_get(:@readiness_work)
      wait_background_work(work);form.update
      H.button(form,'Ready').press
      worker=Timeout.timeout(5) {entered.pop}
      assert(worker!=Thread.current,'Mutacja nie działa w workerze')
      case mode
      when :back then H.button(form,'Back').press
      when :runtime then runtime.close
      when :actor_aba
        session.choose_actor('Bob');session.choose_actor('Alicja')
      when :backend_aba
        session.change_backend('local-test-k03:other');session.change_backend(backend.identity)
      end
      form.update unless mode==:back
      speech=[SpeechOutput.calls.size,NVDA.calls.size]
      release << true
    end
    screen.run
    Timeout.timeout(5) {completed.pop}
    assert(worker.join(5),'Wątek nie zakończył się po zwolnieniu bariery')
    assert(speech==[SpeechOutput.calls.size,NVDA.calls.size],'Spóźniony worker prezentował wynik')
    driver.finish
    assert(program.managed_resources.size==0 && runtime.managed_resources.size==0,'Pozostały zarządzane zasoby')
    assert(session.actor_events.listener_count==0 && session.backend_events.listener_count==0,'Pozostały subskrypcje')
    intents=Dir.glob('tournament-readiness-k03-*/journals/readiness-v1/*/*.intent',base:File.expand_path(directory))
    assert(intents.size==1,'Zamknięcie zgubiło pierwotny zamiar')
    session.close
  end
  puts "PASS native #{mode}: Work bez kill, trwały intent i brak spóźnionej prezentacji/subskrypcji"
end
