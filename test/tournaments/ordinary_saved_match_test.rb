require_relative '../support/temporary_directory'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T = GameRoomTournaments

GameRoomTest::TemporaryDirectory.create('saved-match-') do |directory|
  h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
  program = ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby = LobbyRepository.new(program, transport: h.transports['Alice'], server_tables: Object.new)
  h.as('Alice') { lobby.close_table(h.table) }
  docs = TournamentServerPlanTableSupport::Table.new(user: -> { 'Alice' })
  match = {'match_id' => 'd' * 64, 'leg' => 1, 'number' => 1, 'players' => %w[alice bob]}
  candidate = {'format' => 'round_robin', 'schedule_id' => 'a' * 64, 'publication_digest' => 'b' * 64,
    'roster_generation' => 'c' * 64, 'game_id' => h.game.id, 'game_options' => h.game.default_options,
    'publication_ref' => {'author' => 'alice', 'publication_key' => 'fixture'}, 'roster' => %w[alice bob], 'matches' => [match]}
  journal = T::OperationJournal.new(directory: directory, owner: 'alice', backend_identity: 'saved-test')
  service = T::OrdinaryMatchService.new(program: program, registry: GameRoomGames::CATALOG, lobby: lobby,
    games: h.repositories['Alice'], transport: h.transports['Alice'], table: docs, journal: journal,
    source: -> { {'candidate' => candidate, 'tournament_id' => 5} }, user: -> { 'Alice' })
  begin
    table = h.as('Alice') { service.open_match(match_id: match['match_id'], leg: 1) }
    h.instance_variable_set(:@table, table)
    h.as('Bob') { h.transports['Bob'].join_room(table, 'Bob') }
    session = h.as('Alice') do
      h.repositories['Alice'].start_session(table: table, game: h.game.id, players: h.users,
        options: JSON.generate(h.game.default_options), **service.start_parameters(table, players: h.users))
    end
    h.instance_variable_set(:@session, session)
    binding = service.instance_variable_get(:@bindings).fetch(table['__id']).first
    writes = docs.insert_count
    callbacks = [
      -> { service.saved_match_reference(table, session) },
      -> { service.check_saved_match({}, allow_linked: true, allow_prepared: true) },
      -> { service.prepare_saved_match({}, table) },
      -> { service.start_saved_match({}, table) },
      -> { service.bind_resumed_match({}, table, session) }
    ]
    callbacks.each do |callback|
      error = assert_raises(T::OrdinaryMatchService::Blocked, &callback)
      assert_equal(:tournament_saved_game_disabled, error.code)
    end
    assert_equal(writes, docs.insert_count, 'A blocked continuation wrote tournament data')

    12.times do
      replay = h.replay('Alice')
      break if replay.finished?
      h.submit(replay.current_player, h.game.legal_actions(replay, replay.current_player).first)
    end
    snapshot = h.repositories['Alice'].snapshot_for(session, force_events: true)
    replay = h.game.replay(snapshot.session, snapshot.events, h.repositories['Alice'])
    assert(replay.finished?, 'Control game did not finish')
    capture = T::OrdinaryMatchResults.capture(registry: GameRoomGames::CATALOG, binding: binding,
      session: snapshot.session, replay: replay, events: snapshot.events)
    %w[__restored __archive_id].each do |key|
      error = assert_raises(T::Publication::Invalid) do
        T::OrdinaryMatchResults.capture(registry: GameRoomGames::CATALOG, binding: binding,
          session: snapshot.session.merge(key => true), replay: replay, events: snapshot.events)
      end
      assert_equal(:tournament_saved_game_disabled, error.code)
    end

    # Explicit historical fixtures emulate documents written before the ban.
    # No public continuation method is used, and no real server is contacted.
    legacy = T::Publication::Data.copy(binding)
    legacy['continuation'] = {'archive_id' => SecureRandom.uuid, 'save_checksum' => '1' * 64,
      'event_count' => snapshot.events.size,
      'prefix_digest' => Digest::SHA256.hexdigest(JSON.generate(snapshot.events.map { |event| event.slice('actor', 'action', 'value') }))}
    legacy = T::Publication::Data.copy(legacy)
    assert(service.send(:valid_binding?, legacy, candidate, match), 'Historical fixture has an invalid binding')
    document = {'kind' => 'ordinary-match-continuation-v1', 'publication_ref' => candidate['publication_ref'],
      'schedule_id' => candidate['schedule_id'], 'match_id' => match['match_id'], 'leg' => 1,
      'previous_digest' => service.send(:binding_digest, binding), 'binding' => legacy}
    key = service.send(:continuation_anchor, candidate, 5, match, binding)
    service.send(:publish_document, document, key) { true }
    assert_equal(legacy, service.send(:read_match_binding, candidate, 5, match, nil),
      'Historical continuation chain became unreadable')

    legacy_capture = capture.merge('binding_digest' => service.send(:binding_digest, legacy))
    assert_raises(T::Publication::Invalid) do
      T::OrdinaryMatchResults.read(repository: Object.new, registry: Object.new, transport: Object.new,
        table: table, binding: legacy)
    end
    before = [docs.insert_count, journal.list]
    assert_raises(T::OrdinaryMatchService::Blocked) { service.collect([legacy, candidate, 5, match, legacy_capture]) }
    assert_equal(before, [docs.insert_count, journal.list], 'Collection retained or published a restored result')

    continuation_op = journal.list.find { |row| JSON.parse(row['values']['document_json'])['kind'] == 'ordinary-match-continuation-v1' }
    assert_raises(T::OrdinaryMatchService::Blocked) { service.reconcile(continuation_op['id']) }
    assert_equal(before, [docs.insert_count, journal.list], 'Continuation recovery mutated historical state')

    retained_result = T::ServerPlanDocument.copy_document(legacy_capture.merge('publication_ref' => candidate['publication_ref']))
    result_key = service.send(:anchor, candidate, 5, match, 'result')
    operation = journal.prepare(kind: 'plan_document', intent_id: 'ordinary-document:' + result_key['operation_key'],
      values: result_key.merge('kind' => 'plan_document', 'document_json' => JSON.generate(retained_result)))
    before = [docs.insert_count, journal.list]
    error = assert_raises(T::OrdinaryMatchService::Blocked) { service.reconcile(operation['id']) }
    assert_equal(:tournament_saved_game_disabled, error.code)
    assert_equal(before, [docs.insert_count, journal.list], 'Retained result recovery republished a saved match')

    # Reading an already published historical result remains supported.
    service.send(:publish_document, retained_result, result_key) { true }
    view = service.result_view
    assert_equal(1, view['results'].size)
    assert_equal(match['match_id'], view['results'].first['match_id'])
  ensure
    service.close
  end
end
puts 'PASS tournament save policy: API denials, restored-session result guards, retained-operation prohibition and historical result readability'
