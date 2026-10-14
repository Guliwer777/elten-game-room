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
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/hub'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture
now = Time.utc(2026, 10, 11, 12).to_i
provider = T::LocalTestTables.new(directory: File.join(fixture[:program].data_path, 'simulated-server'),
  user: -> { F::OWNER }, clock: -> { now })
original = T::ServerTrialWorkspace::Provider.method(:new)
T::ServerTrialWorkspace::Provider.define_singleton_method(:new) { provider }
driver = TournamentNativeDriver.new
driver.step(L.call('Tournaments'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call("Server test — guliwer's separate application")))
end
driver.step(L.call('Server tournament test'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Create and publish tournament')))
end
driver.step(L.call('Game'), [13]) do |form|
  F.field(form, L.call('Tournament name')).set_text('Serwerowy test natywny')
  F.field(form, L.call('Game')).index = GameRoomGames::CATALOG.ids.index('tic_tac_toe') + 1
  form.index = form.fields.index(F.button(form, L.call('Publish in server test')))
end
driver.step(L.call('Server tournament test'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Tournament list')))
end
driver.step(L.call('Tournaments'), [13])
driver.step(L.call('Tournament details'), [13]) do |form|
  assert(form.fields.none? { |field| field.respond_to?(:header) && field.header == L.call('Virtual player name (local test only)') }, 'Virtual actor control in server view')
  F.button(form, L.call('Matches, groups and standings'))
  F.button(form, L.call('Edit tournament'))
  F.button(form, L.call('Delete tournament'))
  form.index = form.fields.index(F.button(form, L.call('Matches, groups and standings')))
end
driver.step(L.call('Matches, groups and standings'), [27]) do |form|
  assert_equal([L.call('Refresh'), L.call('Back')], form.fields.grep(Button).map(&:label))
  assert(form.fields.first.text.include?(L.call('Registration is still open. Matches and groups will be created after it closes.')), 'Missing registration deadline explanation')
end
driver.step(L.call('Tournament details'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Leave tournament')))
end
driver.step(L.call('Tournament details'), [27])
driver.step(L.call('Tournaments'), [27])
driver.step(L.call('Server tournament test'), [27])
driver.step(L.call('Tournaments'), [27])
messages = []
args = I.args(fixture).merge(clock: -> { now }, alert: ->(message) { messages << message })
# Root hub has no clock option; pass it to its server child in this isolated test.
child_new = T::ServerTrialHub.method(:new)
T::ServerTrialHub.define_singleton_method(:new) { |**values| child_new.call(**values, clock: -> { now }) }
begin
  T::Hub.new(**args.reject { |key, _| key == :clock }).run
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
  T::ServerTrialWorkspace::Provider.define_singleton_method(:new, original)
  T::ServerTrialHub.define_singleton_method(:new, child_new)
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS Polish native server UI: publication, creator enrollment, list, withdrawal, organizer controls and no virtual/local execution actions'
