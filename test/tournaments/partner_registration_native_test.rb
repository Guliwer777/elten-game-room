require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/public_preview'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language'=>'pl','known_languages'=>['pl']})
label = ->(s) { GameRoomContent.utf8(GameRoomLocalization.translate(s)) }
state = I.fixture(names: %w[Alpha Beta Gamma Delta], game: 'spades', game_options: {'team_size'=>2}, players_per_match: 4)
state[:now] = 150
factory = ->(actor) { T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG, user: -> { F::OWNER },
 actor: actor, alert: ->(m) { raise m }, clock: -> { state[:now] }) }
workspace = factory.call('Organizator')
snapshot = workspace.load
driver = TournamentNativeDriver.new
driver.step(label.call('Tournament details'), [13]) do |form|
 F.field(form, label.call('Virtual player name (local test only)')).set_text('Epsilon')
 F.field(form, label.call('Partner')).index = 2
 form.index = form.fields.index(F.button(form, label.call('Join tournament')))
end
driver.step(label.call('Tournament details')) do |form|
 assert(F.field(form, label.call('Tournament details')).text.include?('Beta — Epsilon'), 'Missing joined pair in tournament details')
 assert(!F.field(form, label.call('Partner')).options.include?('Beta'), 'Occupied partner still offered')
end
driver.step(label.call('Tournament details'), [27])
T::PublicPreview.new(program: state[:program], registry: GameRoomGames::CATALOG, publication: snapshot['announcements'].first,
 snapshot: snapshot, load: workspace.method(:load), join: workspace.method(:join), actor: workspace.actor, mode_label: workspace.mode_label,
 join_virtual: ->(id,name) { factory.call(name).join(id) }, set_partner: ->(id,actor,partner,intent) { factory.call(actor).set_partner(id,actor,partner,intent) }, alert: ->(m) {}).wait
driver.finish
assert_equal([%w[beta epsilon]], workspace.load['pairs'].map { |pair| pair['accounts'] })
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native Polish enrollment with selected partner and updated free-partner list'
