# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/match_entry_screen'
require_relative '../../lib/game_room_background'
include GameRoomTest::Assertions
H = TournamentLocalHubTest
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

# Bliskie granice tego samego resume, bez nowej macierzy reguł backendu.
[:lease, :actor, :backend, :runtime, :primary, :primary_expire, :primary_cleanup, :cleanup].each do |mode|
  Dir.mktmpdir('r1-granica-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    runtime = program.class.app_runtime
    session = T::LocalReadinessSession.new
    session.choose_actor('Alicja')
    owner = T::LocalTestDialogs::Owner.new(-> {'RealOwner'}, ->(message) { raise message })
    workspace = T::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Alicja', alert: ->(message) { raise message },
      clock: -> {201}, readiness_session: session)
    screen = T::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    primary = NoMethodError.new('Pierwotny błąd powrotu planu')
    primary.set_backtrace(['powrot_planu.rb:11'])
    cause = ArgumentError.new('Bezpośrednia przyczyna powrotu')
    secondary = IOError.new('Wtórny błąd fokusu')
    secondary.set_backtrace(['fokus_rodzica.rb:13'])
    observed = parent = nil
    calls = []; reached = 0; cleanup_calls = 0; counts = after = nil
    expire = [:lease, :actor, :backend, :runtime, :primary_expire].include?(mode)
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == T::LocalReadinessBackend && [:accept, :store].include?(event.method_id)
        calls << event.method_id
      end
    end
    driver.step('My tournaments') do |form|
      parent = form
      complete = lambda do
        wait_background_work(screen.instance_variable_get(:@readiness_work))
        form.update
      end
      H.button(form, 'Check status').press; complete.call
      list = H.field(form, 'My matches'); list.index = 2; list.trigger(:move); complete.call
      form.index = form.fields.index(list)
      H.button(form, 'Prepare local test plan').press
      begin
        complete.call
      rescue Exception => error
        observed = error
      end
      after = [SpeechOutput.calls.size, NVDA.calls.size]
      assert(!screen.instance_variable_get(:@readiness_pending), 'Utrata guardu/błąd uruchomiły accept')
    end
    driver.step('Local test plan', [13]) do |form|
      form.index = form.fields.index(H.button(form, mode == :cleanup ? 'Cancel' : 'Accept local test plan'))
    end
    driver.on_resume = lambda do |closed|
      next unless closed.fields.first.header == 'Local test plan'
      reached += 1
      assert(screen.instance_variable_get(:@busy), 'Granica resume poza busy')
      H.field(parent, 'My tournaments').index = 1
      H.field(parent, 'My matches').index = 0
      # Cleanup ma własny błąd, lecz nie może zastąpić primary/cause/backtrace.
      if [:primary_cleanup, :cleanup].include?(mode)
        parent.fields.each do |field|
          field.on(:before_focus) do
            next unless cleanup_calls == 0
            cleanup_calls += 1
            mode == :cleanup ? (raise primary, cause: cause) : (raise secondary, cause: nil)
          end
        end
      end
      case mode
      when :lease, :primary_expire then screen.controller.close
      when :actor
        session.choose_actor('Bob'); session.choose_actor('Alicja')
      when :backend
        identity = screen.controller.instance_variable_get(:@readiness_connection).instance_variable_get(:@backend).identity
        session.change_backend('local-test-k03:obcy'); session.change_backend(identity)
      when :runtime then runtime.close
      end
      counts = [SpeechOutput.calls.size, NVDA.calls.size]
      raise primary, cause: cause if [:primary, :primary_expire, :primary_cleanup].include?(mode)
    end
    driver.step('My tournaments', [27]) unless expire
    trace.enable { screen.run }
    driver.finish
    assert_equal(1, reached, 'Nie osiągnięto dokładnie jednego resume')
    assert_equal([], calls, 'Niedozwolone accept/store po utracie guardu lub błędzie')
    assert_equal([], Dir.glob('**/sandbox-k03.json', base: directory), 'Utrwalono plan mimo odmowy')
    if [:primary, :primary_expire, :primary_cleanup, :cleanup].include?(mode)
      assert(observed.equal?(primary), 'Zgubiono obiekt NoMethodError')
      assert(observed.cause.equal?(cause), 'Zmieniono bezpośredni cause')
      assert_equal(['powrot_planu.rb:11'], observed.backtrace, 'Zmieniono backtrace')
    else
      assert_equal(nil, observed, 'Bezpieczne zamknięcie zgłosiło błąd')
    end
    assert_equal(counts, after, 'Prezentacja po utracie lease') if expire
    assert_equal(1, cleanup_calls, 'Nieosiągnięte cleanup') if [:primary_cleanup, :cleanup].include?(mode)
    assert_equal([0, 0], [program.managed_resources.size, runtime.managed_resources.size], 'Pozostały zasoby')
    assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count], 'Pozostały subskrypcje')
    session.close
  end
  puts "PASS R1 granica #{mode}: zero accept/store, guard, cleanup i niezmieniony primary"
end
