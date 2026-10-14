require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/local_participant_manager'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language'=>'pl','known_languages'=>['pl']})
label = ->(s) { GameRoomContent.utf8(GameRoomLocalization.translate(s)) }
state = I.fixture(names: %w[Alpha Beta Gamma Delta], game: 'spades', game_options: {'team_size'=>2}, players_per_match: 4)
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG, user: -> { F::OWNER },
 actor: 'Organizator', alert: ->(m) { raise m }, clock: -> { state[:now] })
owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(m) { raise m })
driver = TournamentNativeDriver.new
driver.step(label.call('Registered participants'), [13]) do |form|
 F.field(form, label.call('Registered participants')).index = 0
 F.field(form, label.call('Partner')).index = 2
 form.index = form.fields.index(F.button(form, label.call("Change selected participant's partner")))
end
driver.step(label.call('Registered participants')) do |form|
 assert(F.field(form, label.call('Tournament pairs')).text.include?('alpha — beta'), 'Native pair view missing saved pair')
end
driver.step(label.call('Registered participants'), [27])
T::LocalParticipantManager.new(program: state[:program], workspace: workspace, owner: owner,
 publication: workspace.load['announcements'].first, confirm: ->(m) { true }, alert: ->(m) {}).run
driver.finish
assert_equal([%w[alpha beta]], workspace.load['pairs'].map { |row| row['accounts'] })
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS Polish native partner selector and durable organizer pair change'
