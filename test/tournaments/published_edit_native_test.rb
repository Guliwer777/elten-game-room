require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language'=>'pl','known_languages'=>['pl']})
label = ->(s) { GameRoomContent.utf8(GameRoomLocalization.translate(s)) }
state = I.fixture
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG, user: -> { F::OWNER },
 actor: 'Organizator', alert: ->(m) { raise m }, clock: -> { state[:now] })
row = workspace.load['announcements'].first
driver = TournamentNativeDriver.new
driver.step(label.call('Tournament name'), [13]) do |form|
 assert_equal(row['title'], F.field(form, label.call('Tournament name')).text)
 F.field(form, label.call('Tournament name')).set_text('Edytowany lokalny turniej')
 form.index = form.fields.index(F.button(form, label.call('Save tournament changes')))
end
T::TournamentSetupEditor.new(program: state[:program], registry: GameRoomGames::CATALOG, configure: ->(*) { raise 'Unexpected configuration' },
 publish: ->(**attributes) { workspace.edit_tournament(tournament_id: row['__id'], intent_id: 'native-edit', **attributes) },
 alert: ->(m) { raise m }, clock: -> { state[:now] }, publication: row).wait
driver.finish
assert_equal('Edytowany lokalny turniej', workspace.load['announcements'].first['title'])
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native Polish published tournament editor with existing configuration'
