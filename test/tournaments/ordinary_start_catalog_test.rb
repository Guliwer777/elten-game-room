require 'tmpdir'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'

T = GameRoomTournaments
checked = []
GameRoomGames::CATALOG.ids.each do |game_id|
  game = GameRoomGames::CATALOG.build(game_id)
  options = game.normalize_options(game.default_options)
  next if game.private_table_required?(options)
  count = game.tournament_capabilities(options: options)[:player_counts].find do |size|
    size.between?(2, 8) && game.team_size(options, player_count: size).zero? &&
      game.tournament_competitive_roster?(player_count: size, options: options)
  end
  next unless count
  users = %w[Alice Bob Carol Dave Eve Frank Grace Henry].take(count)
  h = NativeRoomHarness.new(game: game, users: users, options: options)
  program = ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby = LobbyRepository.new(program, transport: h.transports['Alice'], server_tables: Object.new)
  h.as('Alice') { lobby.close_table(h.table) }
  docs = TournamentServerPlanTableSupport::Table.new(user: -> { 'Alice' })
  candidate = {'schedule_id'=>'a'*64, 'publication_digest'=>'b'*64, 'roster_generation'=>'c'*64,
    'game_id'=>game.id, 'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'game_options'=>options, 'roster'=>users.map(&:downcase),
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>users.map(&:downcase)}]}
  Dir.mktmpdir('tournament-start-') do |directory|
    journal = T::OperationJournal.new(directory: directory, owner: 'alice', backend_identity: 'catalog-start')
    service = T::OrdinaryMatchService.new(program: program, registry: GameRoomGames::CATALOG,
      lobby: lobby, games: h.repositories['Alice'], transport: h.transports['Alice'], table: docs,
      journal: journal, source: -> { {'candidate'=>candidate,'tournament_id'=>5} }, user: -> { 'Alice' })
    begin
      room = h.as('Alice') { service.open_match(match_id: 'd'*64, leg: 1) }
      # Use exactly the option preparation used by the ordinary Start button.
      [users, users.reverse].uniq.each do |arrivals|
        displayed = game.options_for_team_roster(game.new_game_options(game.options_from_json(room['game_options'])), players: arrivals)
        prepared = service.start_parameters(room, players: arrivals, options: displayed)
        assert_equal(users, prepared[:players], "#{game.id}: wrong planned seats")
        assert(prepared[:requested_session_id].positive?, "#{game.id}: missing bound game")
      end
      failure = assert_raises(T::OrdinaryMatchService::Blocked) do
        service.start_parameters(room, players: users[0...-1]+['Intruder'], options: options)
      end
      assert_equal(:wrong_game_players, failure.code, "#{game.id}: participant guard")
      active = h.broker.endpoint('Alice').sessions.find { |session| session.id == room['__live_session_id'] }
      expected_private = GameRoomPrivateCards.supported?(game.id) ? GameRoomPrivateCards::VERSION : nil
      assert_equal(expected_private, active.metadata['private_cards'], "#{game.id}: bound tournament private-hand capability disagrees with registry")
      h.as('Alice') { lobby.close_table(room) }
      checked << game.id
    ensure
      service.close
    end
  end
end
assert(checked.size >= 25, "Too few ordinary tournament games checked: #{checked.inspect}")
puts "PASS ordinary Start option/seat contract for #{checked.size} games: #{checked.join(', ')}"
