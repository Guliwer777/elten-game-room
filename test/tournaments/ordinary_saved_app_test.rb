require_relative '../support/temporary_directory'
require_relative '../support/saved_games_ui'
require_relative '../support/tournament_server_plan_table'
T = GameRoomTournaments

GameRoomTest::TemporaryDirectory.create('saved-app-') do |directory|
  broker = NativeLiveSessionsBroker.new
  app = SaveAppDriver.new(broker)
  $game_room_test_user = 'Alice'
  game = GameRoomGames::TicTacToe.new
  match = {'match_id' => 'd' * 64, 'leg' => 1, 'number' => 1, 'players' => %w[alice bob]}
  candidate = {'format' => 'round_robin', 'schedule_id' => 'a' * 64, 'publication_digest' => 'b' * 64,
    'roster_generation' => 'c' * 64, 'game_id' => game.id, 'game_options' => game.default_options,
    'publication_ref' => {'author' => 'alice', 'publication_key' => 'fixture'}, 'roster' => %w[alice bob], 'matches' => [match]}
  docs = TournamentServerPlanTableSupport::Table.new(user: -> { 'Alice' })
  service = T::OrdinaryMatchService.new(program: ProgramDouble.new(broker.endpoint('Alice')),
    registry: GameRoomGames::CATALOG, lobby: app.lobby, games: app.games, transport: app.transport, table: docs,
    journal: T::OperationJournal.new(directory: directory, owner: 'alice', backend_identity: 'saved-app'),
    source: -> { {'candidate' => candidate, 'tournament_id' => 5} }, user: -> { 'Alice' })
  begin
    app.instance_variable_set(:@ordinary_tournament_services, {'fixture' => service})
    table = service.open_match(match_id: match['match_id'], leg: 1)
    bob = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Bob')))
    bob.join_room(table, 'Bob')
    session = app.games.start_session(table: table, game: game.id, players: %w[Alice Bob],
      options: JSON.generate(game.default_options), **service.start_parameters(table, players: %w[Alice Bob]))
    entries = broker.cores[table['__live_session_id']].entries.size
    assert(!app.send(:save_current_game, table, session, game), 'App saved a tournament game')
    assert_equal(entries, broker.cores[table['__live_session_id']].entries.size, 'Denied save froze or changed the game')
    assert(app.send(:saved_games).list.empty?, 'Denied save uploaded an archive')
    assert(app.transport.current_room('Alice'), 'Denied save left the native table')
    assert(app.notices.last.include?('Tournament games cannot'), 'The restriction has no player-facing explanation')

    # Historical fixture, not a new save through the now-forbidden put path.
    binding = service.instance_variable_get(:@bindings).fetch(table['__id']).first
    old = {'format' => 1, 'game_schema' => game.saved_game_schema_version, 'id' => SecureRandom.uuid,
      'owner' => 'Alice', 'saved_at' => Time.now.to_i, 'game' => game.id, 'table_name' => 'Historical match',
      'private' => false, 'players' => %w[Alice Bob], 'options' => JSON.generate(game.default_options),
      'game_time' => Time.now.to_i, 'events' => [],
      'tournament' => table['tournament_match'].merge('binding_digest' => Digest::SHA256.hexdigest(JSON.generate(binding)))}
    saves = app.send(:saved_games)
    old['checksum'] = saves.send(:checksum, old)
    saves.persist(old)
    assert_equal(old, saves.validate(saves.fetch(old['id']), game: game), 'Historical archive became unreadable')
    before = [broker.cores.size, docs.insert_count, broker.cores[table['__live_session_id']].entries.size]
    assert(app.send(:create_saved_game_table, old).nil?, 'Old archive created a tournament continuation')
    assert(app.send(:resume_saved_game_at_table, table.merge('resume_save_id' => old['id']), app.room_state(table)).nil?,
      'Old marked table restored a saved match')
    assert_equal(before, [broker.cores.size, docs.insert_count, broker.cores[table['__live_session_id']].entries.size])
    assert_equal(old, saves.fetch(old['id']), 'Rejection modified or consumed the historical archive')

    # An unmarked waiting room cannot launder the old archive into a new game.
    app.lobby.close_table(table)
    ordinary = app.lobby.create_table(name: 'Ordinary', game: game.id, owner: 'Alice', game_options: '{}', resume_save_id: old['id']).table
    bob.join_room(ordinary, 'Bob')
    assert(app.send(:resume_saved_game_at_table, ordinary, app.room_state(ordinary)).nil?, 'Unmarked room restored a tournament archive')
    assert(app.games.session_for_table(ordinary).nil?, 'Denied restoration published game_started')
    assert_equal(old, saves.fetch(old['id']))
    saves.delete(old['id'])
    assert(saves.list.empty?, 'Historical archive could not be explicitly deleted')

    # Ordinary play keeps saving, original seats, invitation and consumption.
    ordinary_session = app.games.start_session(table: ordinary, game: game.id, players: %w[Alice Bob], options: '{}')
    assert(app.send(:save_current_game, ordinary, ordinary_session, game), 'Ordinary saving was disabled')
    saved = saves.fetch(saves.list.first.fetch('id'))
    resumed_table = app.send(:create_saved_game_table, saved)
    assert(resumed_table && !resumed_table.key?('tournament_match'), 'Ordinary continuation acquired a tournament marker')
    bob.join_room(resumed_table, 'Bob')
    resumed = app.send(:resume_saved_game_at_table, resumed_table, app.room_state(resumed_table))
    assert(resumed && resumed['__archive_id'], 'Ordinary archive did not resume')
    assert_equal(%w[Alice Bob], app.games.players_for(resumed))
    assert(saves.fetch(saved['id']).nil?, 'Ordinary restoration did not consume its saved copy')
  ensure
    service.close
  end
end
puts 'PASS app tournament save prohibition: no mutation, readable/deletable old archive, no unmarked-room bypass, ordinary save/restore preserved'
