require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/local_participant_manager'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
state = I.fixture(names: %w[Alpha Beta Gamma Delta])
messages, confirmations = [], []
workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
  user: -> { F::OWNER }, actor: 'Organizator', alert: ->(m) { messages << m }, clock: -> { state[:now] })
publication = workspace.load['announcements'].first
owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(m) { raise m })
driver = TournamentNativeDriver.new
driver.step(L.call('Registered participants'), [13]) do |form|
  list = F.field(form, L.call('Registered participants'))
  list.index = list.options.index('Delta')
  form.index = form.fields.index(F.button(form, L.call('Remove selected participant')))
end
driver.step(L.call('Registered participants')) do |form|
  list = F.field(form, L.call('Registered participants'))
  assert_equal(%w[Alpha Beta Gamma], list.options)
end
driver.step(L.call('Registered participants'), [27])
T::LocalParticipantManager.new(program: state[:program], workspace: workspace, owner: owner, publication: publication,
  confirm: ->(m) { confirmations << m; true }, alert: ->(m) { messages << m }).run
driver.finish
assert_equal(1, confirmations.size)
assert(messages.include?(L.call('Participant removal confirmed.')), 'Missing Polish removal confirmation')
assert_equal(3, workspace.load['members'].size)
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native Polish organizer participant removal, confirmation and refreshed roster'
