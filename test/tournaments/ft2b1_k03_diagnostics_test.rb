# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
H = TournamentLocalHubTest
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
Dir.mktmpdir('k03-diagnostyka-', ENV.fetch('TMPDIR')) do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  now = 200
  owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(message) { raise message })
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: owner.method(:current), actor: 'Bob', alert: ->(message) { raise message }, clock: -> { now })
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  driver = TournamentNativeDriver.new
  observed = []
  validator = G::ScheduleSource.method(:validate_diagnostics!)
  observer = TracePoint.new(:call) do |event|
    data = event.binding.local_variable_get(:data)
    observed << {thread: Thread.current.object_id, members: data.fetch('members'), diagnostics: data.fetch('diagnostics')}
  end
  observer.enable(target: validator, target_thread: nil)
  previous = before = match_id = nil
  driver.step('My tournaments') do |form|
    H.button(form, 'Check status').press
    controller = screen.controller
    assert_equal(:candidate, controller.reason)
    assert_equal(2, controller.view[:tournaments].size)
    assert_equal(6, controller.view[:matches].size)
    provider = workspace.instance_variable_get(:@provider)
    provider.insert_row('tournament_registrations', G::RegistrationProjection.join_values(
      tournament_id: controller.view[:selected_id], operation_key: 'k03-outside-window'))
    outside = workspace.load
    assert(outside['diagnostics']['registrations'].any? { |item| item['code'] == 'outside_window' }, 'Nie osiągnięto legalnego outside_window')
    # Dodatnia kontrola tego samego selektywnego obserwatora na UI i workerze.
    observed.clear
    G::ScheduleSource.validate_diagnostics!(outside)
    worker = Thread.new { G::ScheduleSource.validate_diagnostics!(outside) }
    worker.join
    assert_equal([Thread.current.object_id, worker.object_id], observed.map { |row| row[:thread] })
    observed.clear
    bytes = TournamentMatchEntryTest.files(directory)
    H.button(form, 'Check status').press
    assert_equal(:candidate, controller.reason)
    assert(observed.any? { |row| row[:diagnostics]['registrations'].any? { |item| item['code'] == 'outside_window' } }, 'Refresh ominął walidator legalnego dowodu')
    assert_equal(bytes, TournamentMatchEntryTest.files(directory))
    previous = controller.view
    tournaments = H.field(form, 'My tournaments')
    matches = H.field(form, 'My matches')
    matches.index = 2
    match_id = previous[:matches].fetch(2).fetch('match_id')
    selection = [tournaments.index, tournaments.options.dup, matches.index, matches.options.dup, JSON.generate(previous)]
    own = workspace.load['operations'].select { |op| op['account'] == 'bob' && !op['eligible_ids'].empty? }
    now = 150
    own.each do |operation|
      other = previous[:tournaments].find { |row| row['__id'] != operation['tournament_id'] }
      provider.insert_row('tournament_registrations', G::RegistrationProjection.join_values(
        tournament_id: other.fetch('__id'), operation_key: operation.fetch('operation_key')))
    end
    now = 200
    conflict = workspace.load
    assert(conflict['members'].none? { |member| member['account'] == 'bob' }, 'Konflikt nie usunął członkostwa')
    assert(conflict['diagnostics']['registrations'].any? { |item| item['code'] == 'key_conflict' }, 'Nie osiągnięto konfliktu klucza')
    observed.clear
    before = TournamentMatchEntryTest.files(directory)
    H.button(form, 'Check status').press
    assert_equal(:unresolved_source_diagnostics, controller.reason)
    assert_equal(1, observed.length, 'Odmowa ma nastąpić przed filtrowaniem członkostwa/kandydatem')
    assert_equal(conflict['diagnostics'], observed.first[:diagnostics])
    assert_equal(conflict['members'], observed.first[:members])
    assert(controller.view.equal?(previous), 'Zastąpiono pełny model ostatniego zdrowego widoku')
    assert_equal(selection, [tournaments.index, tournaments.options, matches.index, matches.options, JSON.generate(controller.view)])
    assert(H.field(form, 'Readiness and coordination').text.include?('unresolved conflicts'), 'Brak konkretnego statusu')
    form.accept_button.press
  end
  driver.step('Match details', [27]) do |form|
    content = form.fields.first.text
    assert(content.include?(match_id) && content.include?('Game: chess') && content.include?('unresolved conflicts'), 'Szczegóły nie odpowiadają zachowanemu meczowi i powodowi')
  end
  driver.step('My tournaments', [27])
  begin
    screen.run
    driver.finish
    assert_equal(before, TournamentMatchEntryTest.files(directory), 'Odczyt lub podgląd zmienił bajty źródłowe')
    assert_equal([0, 0], [program.managed_resources.size, program.class.app_runtime.managed_resources.size])
    puts 'PASS K03: rzeczywisty walidator/UI+worker; legalne outside_window; konflikt przed membership; pełny model/kursory/szczegóły i bajty zachowane'
  ensure
    observer.disable
    program.finalize
    program.class.app_runtime.close
  end
end
