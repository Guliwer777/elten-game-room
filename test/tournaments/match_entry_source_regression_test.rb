# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('entry-source-') do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  now = 200
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'RealOwner' }, actor: 'Bob', alert: ->(message) { raise message }, clock: -> { now })
  context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'RealOwner' })
  controller = G::MatchEntry.new(workspace: workspace, context: context)
  controller.refresh
  previous = controller.view
  assert(previous[:tournaments].size == 2 && previous[:matches].size == 6, 'Niepełny wzorzec rejestracji')
  provider = workspace.instance_variable_get(:@provider)
  provider.insert_row('tournament_registrations', G::RegistrationProjection.join_values(
    tournament_id: previous[:selected_id], operation_key: 'outside-window-control'))
  controller.refresh
  assert(controller.reason == :candidate && controller.view[:candidate], 'Legalne outside_window zablokowało odczyt')
  previous = controller.view
  own = workspace.load.fetch('operations').select { |op| op.fetch('account') == 'bob' && !op.fetch('eligible_ids').empty? }
  now = 150
  own.each do |operation|
    other_id = previous[:tournaments].find { |row| row.fetch('__id') != operation.fetch('tournament_id') }.fetch('__id')
    provider.insert_row('tournament_registrations', G::RegistrationProjection.join_values(tournament_id: other_id, operation_key: operation.fetch('operation_key')))
  end
  now = 200
  snapshot = workspace.load
  assert(snapshot.fetch('diagnostics').fetch('registrations').any? { |item| item['code'] == 'key_conflict' }, 'Nie osiągnięto konfliktu')
  assert(snapshot.fetch('members').none? { |item| item['account'] == 'bob' }, 'Konflikt nie usunął członkostwa')
  before = TournamentMatchEntryTest.files(directory)
  TournamentMatchEntryTest.forbid_effects.enable { controller.refresh }
  assert(controller.reason == :unresolved_source_diagnostics, 'Konflikt join błędnie uznano za brak członkostwa')
  assert(controller.view.equal?(previous), 'Konflikt zniszczył ostatni kompletny widok')
  assert(TournamentMatchEntryTest.files(directory) == before, 'Odczyt zmienił magazyn')
  controller.close
end
puts 'PASS 01: konflikt join zachowuje widok; prawdziwe outside_window pozostaje legalne'
