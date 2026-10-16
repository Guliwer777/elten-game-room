if ARGV.first
  previous_native = ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = previous_native
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../support/native_tasks'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/hub'
require_relative '../../lib/tournaments/server_trial_hub'
require File.join(EltenTestHost.root, 'src/ui/controls/static')
Object.const_set(:Static, EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture
fixture[:program].define_singleton_method(:ordinary_tournament_overview) do |publication, workspace:, context:, lease:, **|
  reference = {'author' => publication['__insertion_user'], 'publication_key' => publication['publication_key']}
  workspace.shared_schedule(publication_ref: reference, context: context, lease: lease, include_results: true)
end
now = Time.utc(2026, 10, 11, 12).to_i
provider = T::LocalTestTables.new(directory: File.join(fixture[:program].data_path, 'simulated-server'),
  user: -> { F::OWNER }, clock: -> { now })
plan_table = TournamentServerPlanTableSupport::Table.new(user: -> { F::OWNER })
original_fetch = provider.method(:fetch)
provider.define_singleton_method(:fetch) do |name|
  name == 'tournament_plan_documents' ? plan_table : original_fetch.call(name)
end
original = T::ServerWorkspace::Provider.method(:new)
T::ServerWorkspace::Provider.define_singleton_method(:new) { |**| provider }
driver = TournamentNativeDriver.new
driver.step(L.call('Server tournament test'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Create and publish tournament')))
end
driver.step(L.call('Game'), [13]) do |form|
  form.fields.first.index = GameRoomGames::CATALOG.ids.index('tic_tac_toe')
end
driver.step(nil, [13]) do |form|
  form.index = form.fields.index(form.accept_button)
end
driver.step(L.call('Tournament name'), [13]) do |form|
  F.field(form, L.call('Tournament name')).set_text('Serwerowy test natywny')
  form.index = form.fields.index(F.button(form, L.call('Publish in server test')))
end
driver.step(L.call('Server tournament test'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Tournament list')))
end
driver.step(L.call('Tournaments'), [13]) do |form|
  form.index = 0
end
driver.step(/Serwerowy test natywny/, [13]) do |form|
  assert(form.fields.none? { |field| field.respond_to?(:header) && field.header == L.call('Virtual player name (local test only)') }, 'Virtual actor control in server view')
  actions = form.fields.first
  assert(actions.options.include?(L.call('Manage tournament')), 'Missing organizer menu')
  actions.index = actions.options.index(L.call('Matches')) || raise('Missing matches action')
  form.index = 0
end
driver.step(L.call('Matches'), [27]) do |form|
  assert_equal([L.call('Refresh')], form.fields.each_with_index.filter_map do |control, index|
    control.label if control.is_a?(Button) && !form.instance_variable_get(:@hidden)[index]
  end)
  assert(form.fields.first.options.empty?, 'Matches appeared before registration closed')
  assert(F.field(form, L.call('Information')).text.include?(L.call('Registration is still open. Matches and groups will be created after it closes.')), 'Missing registration deadline explanation')
end
driver.step(/Serwerowy test natywny/, [13]) do |form|
  actions = form.fields.first
  actions.index = actions.options.index(L.call('Leave tournament')) || raise('Missing withdrawal action')
  form.index = 0
end
driver.step(/Serwerowy test natywny/, [27])
driver.step(L.call('Tournaments'), [27])
driver.step(L.call('Server tournament test'), [27])
messages = []
args = I.args(fixture).merge(clock: -> { now }, alert: ->(message) { messages << message })
begin
  T::ServerTrialHub.new(**args).run
  driver.finish
  rows = provider.fetch('tournament_announcements').select
  assert_equal(1, rows.size)
  assert_equal('UTC', rows.first['timezone'])
  events = provider.fetch('tournament_registrations').select
  assert_equal(%w[join withdrawal], events.map { |row| row['kind'] })
  assert_equal([F::OWNER], events.map { |row| row['__insertion_user'] }.uniq)
  assert_equal([L.call('Withdrawal confirmed.')], messages)
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
ensure
  T::ServerWorkspace::Provider.define_singleton_method(:new, original)
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS Polish native server UI: publication, creator enrollment, list, withdrawal, organizer controls and no virtual/local execution actions'
