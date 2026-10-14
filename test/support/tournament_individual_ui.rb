require_relative 'tournament_ft2b1_entry'
require_relative '../../games/catalog'
module TournamentIndividualUI
  extend GameRoomTest::Assertions
  T = GameRoomTournaments
  F = TournamentFT2B1
  module_function
    def fixture(names: %w[Alpha Beta], group_count: nil, places_per_group: nil, rematch: true, group_advancement: nil, participant_limit: nil, game: 'tic_tac_toe', game_options: {}, players_per_match: 2, format: 'round_robin')
    directory = Dir.mktmpdir('individual-ui-', File.expand_path('../../tmp', __dir__))
    program = TournamentEntryContextTest::Program.new(directory)
    sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(F::OWNER.downcase))
    state = {program: program, sandbox: sandbox, plans: File.join(sandbox, 'plans'), actor: 'Organizator', now: 150}
    tables = T::LocalTestTables.new(directory: File.join(sandbox, 'tables'), user: -> { state[:actor] }, clock: -> { state[:now] })
    journal = -> { T::OperationJournal.new(directory: File.join(sandbox, 'journals'), owner: state[:actor], backend_identity: tables.backend_identity) }
    gateway = T::TablesGateway.new(server_tables: tables, user: -> { state[:actor] }, operation_error_classes: [T::LocalTestTables::Error])
    service = -> { T::PublicService.new(gateway: gateway, journal: journal.call, registry: GameRoomGames::CATALOG,
      user: -> { state[:actor] }, backend_identity: tables.backend_identity, clock: -> { state[:now] }) }
    draft = {'name' => 'Individual UI', 'game_id' => game, 'game_options' => game_options, 'format' => format,
      'rematch' => rematch, 'players_per_match' => players_per_match, 'pairing' => 'all_combinations', 'participants' => [],
      'windows' => [{'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00'}]}
    if group_count || group_advancement
      draft.merge!('format' => 'groups_knockout', 'group_count' => group_count, 'places_per_group' => places_per_group, 'group_advancement' => group_advancement)
    end
    draft['participant_limit'] = participant_limit if participant_limit
    published = service.call.publish(draft: draft, intent_id: 'individual-ui-publication', rules: 'Local test',
      registration_opens_at: 100, registration_closes_at: 200, timezone: 'local_test:system')
    assert_equal('confirmed', published['status'])
    row = service.call.list['announcements'].first
    state[:reference] = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
    names.each do |actor|
      state[:actor] = actor
      assert_equal('confirmed', service.call.join(tournament_id: row['__id'])['status'])
    end
    state[:actor], state[:now] = 'Organizator', 201
    state[:tables], state[:journal] = tables, journal
    state
  end
  def args(state)
    F.args(state).merge(registry: GameRoomGames::CATALOG)
  end
  def record(state)
    T::LocalExecutionPlanBackend.new(directory: state[:plans], tables: state[:tables], journal: state[:journal].call,
      actor: state[:actor], registry: GameRoomGames::CATALOG, clock: -> { state[:now] }).accepted_records.first
  end
  def with_connection(state, actor)
    state[:actor] = actor
    session = T::LocalReadinessSession.new
    session.choose_actor(actor)
    owner = -> { F::OWNER }
    workspace = T::LocalWorkspace.new(program: state[:program], registry: GameRoomGames::CATALOG, user: owner,
      actor: actor, alert: ->(message) { raise message }, clock: -> { state[:now] }, readiness_session: session)
    entry = T::EntryContext.new(program: state[:program], runtime: state[:program].class.app_runtime,
      owner_reader: owner, actor: actor, account_events: session.actor_events)
    connection = workspace.individual_connection(context: entry, lease: entry.capture, session: session)
    yield connection
  ensure
    connection&.close
    entry&.close
    session&.close
  end
end
