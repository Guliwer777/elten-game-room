# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/local_test_hub'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
include GameRoomTest::Assertions
T = TournamentLocalHubTest
G = GameRoomTournaments
Form.prepend(T::Script)
program = TournamentEntryContextTest::Program.new
hub = G::LocalTestHub.new(**T.args(program: program))
T.script(->(form) {
  T.button(form, 'Advanced local test tools').trigger(:press)
  T.button(form, 'Change test participant').trigger(:press)
  entry = form.fields.find { |field| field.is_a?(Button) && field.label == 'My matches — readiness and coordination' }
  assert(entry, 'R0: brak osiągalnego przycisku własnych spotkań w prawdziwym LocalTestHub')
  form.index = form.fields.index(entry)
  entry.trigger(:press)
  assert(form.fields[form.index].equal?(entry), 'Powrót zgubił przycisk')
  assert(form.fields.first.text.include?('Test actor: Testowy Bob'), 'Powrót zgubił jawnego aktora')
  form.cancel_button.trigger(:press)
}, T.choose('Testowy Bob'), ->(form) {
  assert(T.field(form, 'My tournaments').is_a?(ListBox), 'Brak listy własnych turniejów')
  assert(T.field(form, 'My matches').is_a?(ListBox), 'Brak listy własnych spotkań')
  assert(T.field(form, 'Readiness and coordination').text.include?('Check status'), 'Brak jawnego polecenia odczytu')
  form.cancel_button.trigger(:press)
}) { hub.run }
assert(program.path_calls.empty?, 'Wejście/Cancel rozpoczęło I/O')
puts 'PASS R0: rzeczywisty LocalTestHub, jawny aktor, ekran, Back do przycisku; brak I/O i skutków'

require_relative '../support/tournament_match_entry'
GameRoomTest::TemporaryDirectory.create('entry-ui-') do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  before = TournamentMatchEntryTest.files(directory)
  hub = G::LocalTestHub.new(**T.args(program: program))
  T.script(->(form) {
    T.button(form, 'Advanced local test tools').trigger(:press)
    T.button(form, 'Change test participant').trigger(:press)
    T.button(form, 'My matches — readiness and coordination').trigger(:press)
    form.cancel_button.trigger(:press)
  }, T.choose('Bob'), ->(form) {
    refresh = form.fields.find { |field| field.is_a?(Button) && field.label == 'Check status' }
    assert(refresh, 'R1 UI: brak polecenia świeżego odczytu własnych zapisów')
    refresh.trigger(:press)
    work = hub.instance_variable_get(:@match_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work, timeout: 15) if work&.busy?
    form.update
    tournaments = T.field(form, 'My tournaments')
    matches = T.field(form, 'My matches')
    assert(tournaments.options.length == 2, 'Nie pokazano dwóch potwierdzonych własnych turniejów')
    2.times do |index|
      tournaments.index = index
      tournaments.trigger(:move)
      wait_background_work(work, timeout: 15) if work&.busy?
      form.update
      data = hub.instance_variable_get(:@match_entry).controller.view
      candidate = data.fetch(:candidate)
      expected = candidate['matches'].select { |match| match['players'].include?('bob') }
      assert(data[:matches] == expected && matches.options.length == expected.length, 'Filtrowanie zmieniło pełne własne składy')
      assert(candidate['roster'] == %w[alicja bob celina dawid], 'Plan nie powstał z całego join')
      readiness = hub.instance_variable_get(:@match_entry).instance_variable_get(:@readiness_state)
      assert(readiness && readiness[:current].nil?, 'Registration must not create a readiness declaration')
      assert(T.field(form, 'Readiness and coordination').text.include?('No local test plan has been accepted'), 'Missing explanation of the unaccepted plan')
      ready = T.button(form, 'Ready')
      ready.trigger(:press)
      T.button(form, 'Propose playing now').trigger(:press)
      controller = hub.instance_variable_get(:@match_entry).controller
      assert(controller.declare_ready == :context_unavailable && controller.propose_now == :context_unavailable, 'Wymuszone handlery dopuściły skutki')
      T.button(form, 'View details').trigger(:press)
    end
    workspace = hub.instance_variable_get(:@workspace)
    native_load = workspace.method(:entry_load)
    workspace.define_singleton_method(:entry_load) do |**args|
      snapshot = native_load.call(**args)
      snapshot.merge('announcements' => snapshot['announcements'].reverse.freeze).freeze
    end
    selected_title = tournaments.options[tournaments.index]
    refresh.trigger(:press)
    wait_background_work(work, timeout: 15) if work&.busy?
    form.update
    assert(tournaments.options[tournaments.index] == selected_title, 'R7 ID: odświeżenie zmieniło wybrany turniej po zmianie kolejności')
    form.cancel_button.trigger(:press)
  }, ->(form) {
    assert(form.fields.first.header == 'Match details', 'Enter nie otworzył szczegółów')
    form.cancel_button.trigger(:press)
  }, ->(form) { form.cancel_button.trigger(:press) }) { TournamentMatchEntryTest.forbid_effects.enable { hub.run } }
  after = TournamentMatchEntryTest.files(directory)
  changed = (before.keys | after.keys).select { |key| before[key] != after[key] }
  assert(changed.all? { |key| key.match?(%r{\Atournament-readiness-k03-[0-9a-f]+/backend/sandbox-k03\.json\.lock\z}) && before[key].nil? && after[key] == '' },
    "Viewing changed data rather than only creating its empty read lock: #{changed.inspect}")
end
puts 'PASS R1 UI: hub → rzeczywiste join → cały Candidate → własne pełne mecze 2/3 osób; Enter tylko szczegóły'

GameRoomTest::TemporaryDirectory.create('entry-reasons-') do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  now, alerts = 199, []
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Bob', alert: ->(message) { alerts << message }, clock: -> { now })
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'RealOwner' }, actor: 'Bob')
  controller = G::MatchEntry.new(workspace: workspace, context: context)
  controller.refresh
  assert(controller.respond_to?(:reason) && controller.reason == :registration_open, 'R2: otwarte zapisy nie mają konkretnego stanu bez fikcyjnego planu')
  assert(controller.view[:candidate].nil? && controller.view[:matches].empty? && alerts.empty?, 'Otwarty kandydat lub alert zamiast stanu')
  now = 200
  controller.refresh
  previous = controller.view
  workspace.define_singleton_method(:entry_load) { |**_| nil }
  controller.refresh
  assert(controller.reason == :read_failed && controller.view.equal?(previous), 'Błąd refresh wyzerował ostatni poprawny widok')
  controller.close
end
puts 'PASS R2: otwarte zapisy bez planu; niepełny odczyt zachowuje ostatni poprawny widok'

GameRoomTest::TemporaryDirectory.create('entry-conflict-') do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Bob', alert: ->(message) { raise message })
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'RealOwner' })
  controller = G::MatchEntry.new(workspace: workspace, context: context)
  controller.refresh
  previous = controller.view
  author = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Organizator', alert: ->(message) { raise message }, clock: -> { 150 })
  author.load['announcements'].each do |publication|
    values = publication.reject { |key, _| key.start_with?('__') || key == 'alias_ids' }
    values['rules'] = 'Konfliktowy alias'
    author.instance_variable_get(:@provider).insert_row(TournamentPublicServiceSupport::ANN, values)
  end
  controller.refresh
  assert(controller.reason == :unresolved_source_diagnostics && controller.view.equal?(previous), 'R2 alias: konflikt źródła wyzerował poprzedni widok zamiast powodu')
  controller.close
end
puts 'PASS R2 alias: rzeczywisty konflikt publikacji nie udaje braku członkostwa ani nie usuwa ostatniego widoku'

GameRoomTest::TemporaryDirectory.create('entry-few-') do |directory|
  program = TournamentEntryContextTest::Program.new(directory)
  now = 150
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Bob', alert: ->(message) { raise message }, clock: -> { now })
  workspace.publish(**TournamentMatchEntryTest.params('chess', timezone: 'local_test:system'))
  workspace.join(workspace.load['announcements'].first['__id'])
  now = 200
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'RealOwner' })
  controller = G::MatchEntry.new(workspace: workspace, context: context)
  controller.refresh
  assert(controller.reason == :too_few_players && controller.view[:candidate].nil?, 'Za mało graczy dało fikcyjny plan')
  assert(workspace.entry_descriptor.keys.sort == %w[actor backend_identity owner], 'Deskryptor ujawnia provider/zasoby')
  controller.close
  stranger = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Obcy', alert: ->(message) { raise message })
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'RealOwner' })
  controller = G::MatchEntry.new(workspace: stranger, context: context)
  controller.refresh
  assert(controller.reason == :no_membership && controller.view[:tournaments].empty?, 'Obcy aktor zobaczył cudze turnieje jako własne')
  controller.close
end
puts 'PASS R2: jeden potwierdzony uczestnik bez planu i obcy aktor bez własnych zapisów'

GameRoomTest::TemporaryDirectory.create('entry-closed-handler-') do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { raise message })
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: owner.method(:current), actor: 'Bob', alert: ->(message) { raise message })
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  T.script(->(form) {
    T.button(form, 'Check status').trigger(:press)
    screen.controller.close
    T.button(form, 'View details').trigger(:press)
    assert(screen.instance_variable_get(:@finished), 'R8 handler: nieaktualne wejście pozostało otwarte')
    assert($local_hub_steps.length == 1, 'R8 handler: uruchomiono dodatkowy formularz')
    $local_hub_steps.clear
  }, ->(_form) { raise 'R8 handler: nieaktualny kontekst otworzył szczegóły' }) { screen.run }
end
