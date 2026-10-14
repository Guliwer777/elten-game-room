# encoding: UTF-8
# Pełne komunikaty istniejącego D1; mapowanie oraz legalna publikacja przez PublicService.
require_relative '../support/tournament_local_test_language'
require_relative '../../tools/support/translation_catalog'
require 'json'
L = TournamentLocalTestLanguage
language, mode = ARGV
raise 'Nieznany tryb' unless %w[pl en fallback].include?(language) && %w[legal mapping].include?(mode)
host, host_before, runtime = L.boot_native(language == 'pl' ? 'pl' : 'en')
require_relative '../support/tournament_match_entry'
require_relative '../support/tournament_local_hub'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
extend GameRoomTest::Assertions
T = GameRoomTournaments
messages = GameRoomTranslationCatalog.message_map(GameRoomTranslationCatalog.read_po(File.join(ENV.fetch('D2B_OUT'), 'source/locale/PL.po')))
if language == 'fallback'
  GameRoomLocalization.boot(directory: File.join(ENV.fetch('D2B_OUT'), 'before/locale'), settings: {'interface_language'=>'pl','known_languages'=>['pl']})
  messages = GameRoomTranslationCatalog.message_map(GameRoomTranslationCatalog.read_po(File.join(ENV.fetch('D2B_OUT'), 'before/locale/PL.po')))
end
label = ->(message) { language == 'en' ? message : (messages[message].to_s.empty? ? message : messages[message]) }
reasons = {
  not_read: 'Use Check status to read your confirmed registrations. No readiness or coordination will be sent.',
  no_membership: 'No confirmed registration for this test participant. Viewing does not join a tournament.',
  registration_open: 'Registration is still open. A schedule candidate cannot be calculated yet.',
  no_players: 'There are too few confirmed participants for a complete match.',
  too_few_players: 'There are too few confirmed participants for a complete match.',
  too_many_players: 'The confirmed roster exceeds the schedule candidate limit.',
  plan_too_large: 'The confirmed roster exceeds the schedule candidate limit.',
  unsupported_format: 'This tournament format does not support a schedule candidate.',
  unresolved_source_diagnostics: 'The registration source contains unresolved conflicts. The last valid view is retained.',
  missing_publication: 'The publication is no longer confirmed. The last valid view is retained.',
  read_failed: 'The status could not be read completely. The last valid view is retained.',
  candidate_missing: 'Use Check status to read your confirmed registrations. No readiness or coordination will be sent.'
}
results = []
cases = mode == 'legal' ? [:unsupported_format, :too_few_players] : [:mapping]
cases.each do |kind|
  Dir.mktmpdir('refusal-completion-', ENV.fetch('TMPDIR')) do |directory|
    if mode == 'mapping'
      program = TournamentMatchEntryTest.prepare(directory)
    else
      program = TournamentEntryContextTest::Program.new(directory)
      fixture = Object.new.extend(TournamentPublicServiceSupport)
      make = ->(actor) { T::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG, user: -> {'RealOwner'}, actor: actor, alert: ->(text) {raise text}, clock: -> {150}) }
      draft = fixture.draft('chess')
      draft['format'] = 'groups_knockout' if kind == :unsupported_format
      author = make.call('Organizator')
      published = author.publish(**fixture.params(draft: draft, timezone: 'local_test:system'))
      assert_equal('confirmed', published['status'], 'Fixture: legalna publikacja')
      id = author.load['announcements'].first['__id']
      names = kind == :unsupported_format ? %w[Alicja Bob] : ['Alicja']
      names.each { |actor| assert_equal('confirmed', make.call(actor).join(id)['status']) }
    end
    hub = T::LocalTestHub.new(**TournamentLocalHubTest.args(program: program, clock: -> {201}))
    driver = TournamentNativeDriver.new
    field = ->(form,name) {L.field(form,label.call(name))}
    button = ->(form,name) {L.button(form,label.call(name))}
    driver.step(label.call('Choose a test participant'), [13]) do |form|
      field.call(form,'Test participant name').set_text('Alicja')
      form.index = form.fields.index(button.call(form,'Use test participant'))
    end
    driver.step(label.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(button.call(form,'My matches — readiness and coordination')) }
    driver.step(label.call('My tournaments')) do |form|
      screen = hub.instance_variable_get(:@match_entry)
      button.call(form,'Check status').press
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work) if work && work.busy?
      form.update
      if mode == 'legal'
        assert_equal(kind, screen.controller.reason, 'Fixture nie osiągnął powodu')
        assert_equal([], screen.controller.view[:matches])
      else
        assert_equal(:candidate, screen.controller.reason)
        assert(!screen.controller.view[:matches].empty?, 'Potrzebny zachowany kandydat D1')
      end
      (mode == 'legal' ? {kind=>reasons.fetch(kind)} : reasons).each do |reason,message|
        # Wąska próba prezentacji każdego kodu D1 nad zachowanym widokiem;
        # nie udaje produkcji tych kodów przez źródło (legal fixture jest wyżej).
        if mode == 'mapping'
          screen.controller.define_singleton_method(:reason) { reason == :candidate_missing ? :candidate : reason }
          if reason == :candidate_missing
            missing = screen.controller.view.merge(candidate: nil, matches: []).freeze
            screen.controller.define_singleton_method(:view) { missing }
          end
        end
        form.fields.each { |control| assert(control.class.name, 'Brak typu natywnej kontrolki') }
        expected = label.call(message)
        before = screen.send(:status_text)
        before_files = TournamentMatchEntryTest.files(directory)
        effects = []
        io = []
        ui_thread = Thread.current
        trace = TracePoint.new(:call, :c_call) do |event|
          effects << event.method_id if event.defined_class == T::LocalReadinessBackend && [:accept,:store].include?(event.method_id)
          io << event.method_id if Thread.current == ui_thread && [:open,:binread,:write,:rename,:flock].include?(event.method_id) && (event.self == File || event.self.is_a?(File))
        end
        trace.enable { button.call(form,'Prepare local test plan').press }
        work = screen.instance_variable_get(:@readiness_work)
        pending = !!screen.instance_variable_get(:@readiness_pending)
        # Nie otwieramy nieoczekiwanego modalu; dowód no-op/odmowy kończy się na akcji.
        wait_background_work(work) if work && work.busy?
        after = field.call(form,'Readiness and coordination').text
        results << {kind: kind, reason: reason, before: before, after: after,
          visible_before: before.split("\r\n").include?(expected), visible_after: after.split("\r\n").include?(expected),
          no_pending: !pending, zero_effects: effects.empty?, no_ui_io: io.empty?, files_unchanged: before_files == TournamentMatchEntryTest.files(directory)}
        # Stary wariant uruchamia prepare na zachowanym kandydacie. Nie przyjmujemy go.
        if mode == 'mapping' && pending
          outcome = work.take
          raise outcome.last if outcome && outcome.last
          screen.instance_variable_set(:@readiness_pending,nil)
        end
      end
      L.read_form(form)
    end
    driver.step(label.call('My tournaments'), [27])
    driver.step(label.call('Local tournament tests'), [27])
    hub.run; driver.finish
    assert_equal(0,program.managed_resources.size)
    assert_equal(0,program.class.app_runtime.managed_resources.size)
  end
end
L.equal(host_before,L.host_snapshot,'Zmieniony słownik hosta')
L.check(L::NativeSources.loaded.values.all? { |encoding| encoding == Encoding::ASCII_8BIT },'Loader nie jest binarny')
File.write(File.join(ENV.fetch('ENTRY_EVIDENCE'),'refusal-cases.json'),JSON.pretty_generate(results),encoding:'UTF-8')
results.each { |row| puts "#{row[:kind]} #{row[:reason]}: #{row.reject { |k,_| [:before,:after].include?(k) }}" }
assert(results.all? { |row| [:visible_before,:visible_after,:no_pending,:zero_effects,:no_ui_io,:files_unchanged].all? { |key| row[key] } }, 'D2B: odmowa musi wyjaśniać Prepare bez zapisu/workera i zachować pełny komunikat D1')
puts "PASS #{language} #{mode}: odmowy, binarne kontrolki i CRLF, brak skutków"
