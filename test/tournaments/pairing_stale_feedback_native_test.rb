require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/public_preview'
require_relative '../../lib/tournaments/participant_manager'
require_relative '../../lib/tournaments/local_participant_manager'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
label = ->(text) { GameRoomContent.utf8(GameRoomLocalization.translate(text)) }
stale_message = label.call('The tournament changed. Refresh its view before changing it again.')

[:participant, :organizer, :local_organizer].each do |mode|
  state = I.fixture(names: %w[Alpha Beta Gamma Delta], game: 'spades',
    game_options: {'team_size' => 2}, players_per_match: 4)
  state[:now] = 150
  alerts = []
  actor = mode == :participant ? 'Delta' : 'Organizator'
  workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG,
    user: -> { F::OWNER }, actor: actor, alert: ->(message) { raise message }, clock: -> { state[:now] })
  publication = workspace.load['announcements'].first
  id = publication['__id']
  pair = lambda do |author, account, partner, intent|
    state[:actor] = author
    gateway = T::TablesGateway.new(server_tables: state[:tables], user: -> { state[:actor] },
      operation_error_classes: [T::LocalTestTables::Error])
    service = T::PublicService.new(gateway: gateway, journal: state[:journal].call,
      registry: GameRoomGames::CATALOG, user: -> { state[:actor] },
      backend_identity: state[:tables].backend_identity, clock: -> { state[:now] })
    service.set_partner(tournament_id: id, account: account, partner: partner, intent_id: intent)
  end
  pair.call('Alpha', 'Alpha', 'Beta', 'alpha-request')
  pair.call('Gamma', 'Gamma', 'Delta', 'gamma-request')
  original_insert = state[:tables].method(:insert_row)
  injected = false
  state[:tables].define_singleton_method(:insert_row) do |table, row|
    if !injected && table == 'tournament_registrations' && row['kind'] == 'pairing' && row['account'] == 'delta'
      injected = true
      pair.call('Beta', 'Beta', 'Alpha', 'beta-confirm')
      state[:actor] = actor
    end
    original_insert.call(table, row)
  end
  set_partner = ->(_id, account, partner, intent) { pair.call(actor, account, partner, intent) }
  driver = TournamentNativeDriver.new
  if mode == :participant
    driver.step(/\AIndividual UI — /, [13]) do |form|
      list = form.fields.first
      list.index = list.options.index(label.call('Team partner'))
      form.index = form.fields.index(list)
    end
    driver.step(label.call('Team'), [13]) do |form|
      list = F.field(form, label.call('Partner'))
      list.index = list.options.index(label.call('Confirm partnership with %{player}') % {player: 'Gamma'})
      assert(list.index, 'Reciprocal selection must be available before the interleaving')
      form.index = form.fields.index(list)
    end
    driver.step(/\AIndividual UI — /, [27])
    T::PublicPreview.new(program: state[:program], registry: GameRoomGames::CATALOG,
      publication: publication, snapshot: workspace.load, load: workspace.method(:load),
      join: workspace.method(:join), actor: actor, mode_label: workspace.mode_label,
      clock: -> { state[:now] }, set_partner: set_partner, alert: ->(message) { alerts << message }).wait
  else
    workspace.define_singleton_method(:set_partner, &set_partner)
    owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
    driver.step(label.call('Registered participants'), [13]) do |form|
      F.field(form, label.call('Registered participants')).index = 2 # Delta in alphabetical order
      F.field(form, label.call('Partner')).index = 4 # Gamma, after the no-partner entry
      form.index = form.fields.index(F.button(form, label.call("Change selected participant's partner")))
    end
    driver.step(label.call('Registered participants'), [27])
    type = mode == :organizer ? T::ParticipantManager : T::LocalParticipantManager
    type.new(program: state[:program], workspace: workspace, owner: owner, publication: publication,
      confirm: ->(*) { true }, alert: ->(message) { alerts << message }).run
  end
  driver.finish
  assert(injected, 'The competing accepted pair must happen before the tested write')
  assert_equal([%w[alpha beta]], workspace.load['pairs'].map { |row| row['accounts'] })
  assert(alerts.include?(stale_message), "#{mode}: a durable but ignored partner selection must announce the changed tournament")
  assert(!alerts.include?(label.call('Partner choice saved.')), 'No false participant success')
  assert(!alerts.include?(label.call('Pair saved. Refresh to check the current partners.')), 'No false organizer success')
  state[:program].finalize
  state[:program].class.app_runtime.close
end
puts 'PASS native partner race feedback: participant, organizer and local organizer report stale selection without false success'
