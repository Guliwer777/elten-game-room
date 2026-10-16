require_relative '../support/tournament_individual_ui'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture(names: %w[Alpha Beta Gamma Delta])
driver = TournamentNativeDriver.new
driver.step(L.call('Local tournament tests'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Advanced local test tools')))
end
driver.step(L.call('Local tournament tests'))
driver.step(L.call('Local tournament tests'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Change test participant')))
end
driver.step(L.call('Choose a test participant'), [13]) do |form|
  F.field(form, L.call('Test participant name')).set_text('Organizator')
  form.index = form.fields.index(F.button(form, L.call('Use test participant')))
end
driver.step(L.call('Local tournament tests'), [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Browse local test tournaments')))
end
driver.step(L.call('Tournaments'), [13]) do |form|
  form.index = 0
end
driver.step(/Individual UI/, [13]) do |form|
  assert(F.field(form, L.call('Virtual player name (local test only)')), 'Missing virtual registration field')
  actions = form.fields.first
  actions.index = actions.options.index(L.call('Matches')) || raise('Missing matches action')
  form.index = 0
end
driver.step(L.call('Matches, groups and standings'), [27]) do |form|
  value = F.field(form, L.call('Matches, groups and standings')).text
  assert(value.include?('Alpha') && value.include?('Delta'), value)
  assert_equal(12, value.lines.count { |line| line.include?(' — ') })
  assert(!value.match?(/[0-9a-f]{64}/), 'Technical match IDs must not be spoken in the overview')
  assert(value.include?('Mecz 1: Alpha — Beta'), 'Missing readable first match')
  assert(value.include?('Mecz 7, rewanż: Beta — Alpha'), 'Missing explicit return match')
end
driver.step(/Individual UI/, [27])
driver.step(L.call('Tournaments'), [27])
driver.step(L.call('Local tournament tests'), [27])
T::LocalTestHub.new(**I.args(fixture)).run
driver.finish
assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native Polish navigation: tournament details, virtual field, automatic 12 matches and standings'
