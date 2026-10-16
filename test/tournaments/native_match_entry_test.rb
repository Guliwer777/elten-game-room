# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
include GameRoomTest::Assertions
T = TournamentLocalHubTest
G = GameRoomTournaments
Dir.mktmpdir('entry-native-', ENV.fetch('TMPDIR')) do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  runtime = program.class.app_runtime
  ui = Thread.current
  calls = []
  native_path = program.method(:data_path)
  program.define_singleton_method(:data_path) do
    calls << [Thread.current, Programs.current_runtime]
    assert(Thread.current != ui, 'R9: data_path uruchomiono na UI')
    assert(Programs.current_runtime.equal?(runtime), 'R9: worker nie otrzymał runtime właściciela; pożyczył obcą scenę')
    native_path.call
  end
  driver = TournamentNativeDriver.new
  driver.open_test_participant
  driver.step('Choose a test participant', [13]) do |form|
    T.field(form, 'Test participant name').set_text('Bob')
    form.index = form.fields.index(T.button(form, 'Use test participant'))
  end
  driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(T.button(form, 'My matches — readiness and coordination')) }
  driver.step('My tournaments', [13]) { |form| form.index = form.fields.index(T.button(form, 'Check status')) }
  driver.step('My tournaments', [27]) do |form|
    assert(T.field(form, 'My tournaments').options.length == 2, 'Natywny odczyt nie pokazał danych')
    assert(T.field(form, 'My matches').options.length > 0, 'Natywny odczyt nie pokazał własnych spotkań')
  end
  driver.step('Local tournament tests', [27])
  alien = TestTaskRuntime.new('foreign-scene')
  Programs.with_runtime(alien) { G::LocalTestHub.new(**T.args(program: program)).run }
  driver.finish
  assert(calls.length == 1, 'resolve_root wykonano wielokrotnie')
  assert(program.managed_resources.size == 0 && runtime.managed_resources.size == 0, 'Ekran zatrzymał lease')
end
puts 'PASS R9: natywne kontrolki/Tasks, I/O tylko worker z runtime właściciela, jedno data_path i cleanup'

[:success, :io_error].each do |mode|
  Dir.mktmpdir('entry-late-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    runtime = program.class.app_runtime
    gate = Queue.new
    entered = Queue.new
    seen, alerts = [], []
    program.define_singleton_method(:data_path) do
      entered << true
      gate.pop
      seen << :worker_completed
      raise IOError, 'Kontrolowana awaria odczytu' if mode == :io_error
      directory
    end
    owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { alerts << message })
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(message) { alerts << message })
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    driver.step('My tournaments') do |form|
      active = false
      form.fields.each do |field|
        [:set_text, :update_options, :focus].each do |name|
          next unless field.respond_to?(name)
          original = field.method(name)
          field.define_singleton_method(name) do |*args, **kwargs|
            seen << [name, Thread.current] if active
            original.call(*args, **kwargs)
          end
        end
      end
      $entry_task_tick = lambda do
        next if active || entered.empty?
        entered.pop
        runtime.close
        active = true
        gate << true
      end
      begin
        T.button(form, 'Check status').press
      ensure
        $entry_task_tick = nil
      end
      assert(seen == [:worker_completed] && alerts.empty?, 'R8: stary worker po zamknięciu runtime zmienił kontrolkę/alert/fokus')
      active = false
    end
    # D1 automatycznie kończy wygasłe wejście; nie ma już formularza dla Escape.
    screen.run
    driver.finish
    assert(program.managed_resources.size == 0, 'Zamknięcie pozostawiło lease')
  end
end
puts 'PASS R8: bariera rzeczywistego Tasks; zamknięcie runtime odrzuca sukces i błąd starego workera bez prezentacji'

[:details, :help].each do |kind|
  Dir.mktmpdir('entry-modal-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { raise message })
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(message) { raise message })
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    parent, counts, lease = nil, nil, nil
    attacks, chain = 0, []
    attack = lambda do
      attacks += 1
      assert(screen.instance_variable_get(:@busy), 'R7: modal/restore poza busy')
      parent.fields.grep(Button).each(&:press)
      parent.game_room_hotkey_action(1).call
      screen.run
    end
    driver.step('My tournaments') do |form|
      parent = form
      T.button(form, 'Check status').press
      list = T.field(form, 'My matches')
      list.index = 1
      form.index = form.fields.index(list)
      text_field = T.field(form, 'Readiness and coordination')
      text_field.index, text_field.check = 2, 5
      before = [list.options[list.index], text_field.text, text_field.index, text_field.check]
      [:before_focus, :focus].each { |event| list.on(event) { chain << event; attack.call } }
      if kind == :help
        form.game_room_hotkey_action(1).call
      else
        form.accept_button.press
      end
      assert([list.options[list.index], text_field.text, text_field.index, text_field.check] == before, 'R7: modal zgubił ID/tekst/caret')
      assert(chain == [:before_focus, :focus], 'R7: niepojedynczy łańcuch fokusu')
      assert(SpeechOutput.calls.length - counts[0] == 1 && NVDA.calls.length - counts[1] == 1, 'R7: powrót mowy/brajla nie nastąpił dokładnie raz')
      lease = screen.controller.context.capture
    end
    driver.step(kind == :help ? 'Keyboard shortcuts' : 'Match details', [27]) { |_form| attack.call }
    driver.step('My tournaments', [27])
    driver.on_resume = lambda do |form|
      if form.equal?(parent)
        assert(screen.instance_variable_get(:@finished), 'R7: finished dopiero po resume')
        assert(!screen.controller.context.current?(lease), 'R7: lease nadal żyje podczas resume zamkniętego ekranu')
        attack.call
      else
        attack.call
        parent.index = 0
        T.field(parent, 'My matches').index = 0
        counts = [SpeechOutput.calls.length, NVDA.calls.length]
      end
    end
    screen.run
    driver.finish
    assert(attacks >= 4, 'R7: nie osiągnięto gałęzi reentry')
  end
end
puts 'PASS R7: szczegóły/F1/Escape, reentry w modal/resume/before_focus/focus, jedno ogłoszenie, ID/tekst/caret i lease kończony przed resume'

[:modal, :task].product([:account, :backend, :grant]).each do |boundary, kind|
  Dir.mktmpdir('entry-aba-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { raise message })
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(message) { raise message })
    sources = {account: TournamentEntryContextTest::Events.new('realowner'),
      backend: TournamentEntryContextTest::Events.new('fixture:aba'), grant: TournamentEntryContextTest::Events.new('grant-1')}
    context = G::EntryContext.new(program: program, runtime: program.class.app_runtime,
      owner_reader: owner.method(:current), actor: 'Bob', backend_identity: 'fixture:aba',
      account_events: sources[:account], backend_events: sources[:backend], grant_events: sources[:grant])
    controller = G::MatchEntry.new(workspace: workspace, context: context)
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner, controller: controller)
    lease = context.capture
    delivered = 0
    emit = lambda do
      source = sources.fetch(kind)
      initial = source.snapshot[:value]
      source.emit('obca-wartosc')
      source.emit(initial)
      delivered += 2
    end
    driver = TournamentNativeDriver.new
    if boundary == :modal
      driver.step('My tournaments') { |form| form.game_room_hotkey_action(1).call }
      driver.step('Keyboard shortcuts', [27]) { |_| emit.call }
    else
      gate, entered = Queue.new, Queue.new
      program.define_singleton_method(:data_path) { entered << true; gate.pop; directory }
      driver.step('My tournaments') do |form|
        $entry_task_tick = lambda do
          next if entered.empty?
          entered.pop
          emit.call
          gate << true
        end
        begin
          T.button(form, 'Check status').press
        ensure
          $entry_task_tick = nil
        end
      end
    end
    # Callback źródła wygasza okno bez dodatkowego naciśnięcia Escape.
    screen.run
    driver.finish
    assert(delivered == 2 && !context.current?(lease), 'R4: pominięte zdarzenie ABA na natywnej granicy')
    assert(controller.view[:candidate].nil?, 'R4: opublikowano wynik po ABA')
    assert(sources.values.all? { |source| source.listeners.empty? }, 'R4: callbacki pozostały po modalu')
  end
end
puts 'PASS R4 native: 6 granic modal/Tasks × account/backend/grant, każde ABA emituje dwa prawdziwe callbacki; stary wynik odrzucony'

Dir.mktmpdir('entry-owner-', ENV.fetch('TMPDIR')) do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  account, alerts, paths = 'RealOwner', [], 0
  ui = Thread.current
  alert = lambda do |message|
    assert(Thread.current == ui, 'R6: alert na workerze')
    alerts << message
    account = 'RealOwner'
  end
  owner = G::LocalTestDialogs::Owner.new(-> { account }, alert)
  program.define_singleton_method(:data_path) { paths += 1; account = 'ObceKonto'; directory }
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: owner.method(:current), actor: 'Bob', alert: alert)
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner.method(:current))
  controller = G::MatchEntry.new(workspace: workspace, context: context)
  controller.refresh
  assert(!owner.check && alerts.length == 1 && account == 'RealOwner', 'R6: nie osiągnięto B → alert → A')
  controller.refresh
  assert(paths == 1 && controller.view[:candidate].nil? && !context.current?(context.capture), 'R6: powrót konta odblokował stare wejście')
  controller.close
end
puts 'PASS R6: zmiana konta wewnątrz data_path, zatrzask czytnika bez UI, alert na UI przywraca A bez odblokowania'

Dir.mktmpdir('entry-program-error-', ENV.fetch('TMPDIR')) do |directory|
  program = TournamentEntryContextTest::Program.new(directory)
  primary = begin
    begin
      raise IOError, 'Przyczyna pierwotna'
    rescue IOError
      raise NoMethodError, 'Błąd programu odczytu'
    end
  rescue NoMethodError => error
    error
  end
  original_trace, original_cause = primary.backtrace.dup, primary.cause
  program.define_singleton_method(:data_path) { raise primary }
  owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { raise message })
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: owner.method(:current), actor: 'Bob', alert: ->(message) { raise message })
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  driver = TournamentNativeDriver.new
  driver.step('My tournaments') do |form|
    error = assert_raises(NoMethodError) { T.button(form, 'Check status').press }
    assert(error.equal?(primary) && error.cause.equal?(original_cause) && error.backtrace == original_trace, 'Zamaskowano błąd programu/cause/backtrace')
  end
  driver.step('My tournaments', [27])
  screen.run
  driver.finish
end
puts 'PASS błędy programu: rzeczywisty worker i UI zachowują obiekt wyjątku, direct cause i backtrace'
