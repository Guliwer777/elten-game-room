require 'tmpdir'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
require_relative '../../lib/tournaments/server_read_scope'

T = GameRoomTournaments
Dir.mktmpdir('ordinary-read-budget-', ENV.fetch('TMPDIR')) do |directory|
  harness = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
  program = ProgramDouble.new(harness.broker.endpoint('Alice'))
  lobby = LobbyRepository.new(program, transport: harness.transports['Alice'], server_tables: Object.new)
  harness.as('Alice') { lobby.close_table(harness.table) }
  raw = TournamentServerPlanTableSupport::Table.new(user: -> { 'Alice' })
  table = T::ServerReadScope::Table.new(raw, 'read-budget')
  candidate = {
    'format' => 'round_robin', 'schedule_id' => 'a' * 64,
    'publication_digest' => 'b' * 64, 'roster_generation' => 'c' * 64,
    'game_id' => harness.game.id, 'game_options' => harness.game.default_options,
    'publication_ref' => {'author' => 'alice', 'publication_key' => 'fixture'},
    'roster' => %w[alice bob],
    'matches' => (1..24).map { |i| {'match_id' => Digest::SHA256.hexdigest(i.to_s),
      'leg' => 1, 'number' => i, 'players' => %w[alice bob]} }
  }
  service = T::OrdinaryMatchService.new(program: program, registry: GameRoomGames::CATALOG,
    lobby: lobby, games: harness.repositories['Alice'], transport: harness.transports['Alice'],
    table: table, journal: T::OperationJournal.new(directory: directory, owner: 'alice', backend_identity: 'read-budget'),
    source: -> { {'candidate' => candidate, 'tournament_id' => 1} }, user: -> { 'Alice' },
    read_scope: ->(&block) { T::ServerReadScope.run('read-budget', &block) })
  requests = []
  raw.on_select = -> { requests << :read }
  raw.on_insert = ->(*) { requests << :write }
  candidate['matches'].each_with_index do |match, index|
    room = harness.as('Alice') { service.open_match(match_id: match['match_id'], leg: 1) }
    if index.zero?
      requests.clear
      reopened = harness.as('Alice') { service.open_match(match_id: match['match_id'], leg: 1) }
      assert_equal(room['__live_session_id'], reopened['__live_session_id'])
      assert_equal(0, requests.count(:write), 'Reopening created another binding')
      assert(requests.count(:read) <= 4, 'Reopening reread complete creator/binding evidence')
    end
    harness.as('Alice') { lobby.close_table(room) }
  end
  requests.clear
  view = service.result_view
  assert_equal([], view['results'])
  assert_equal(0, view['standings'].sum { |row| row['played'].to_i })
  assert_equal(96, raw.insert_count, 'Creator and binding documents were not retained')
  assert_equal(0, requests.count(:write), 'Displaying results must not write a plan')
  assert(requests.count(:read) <= 4, 'Binding successors were read separately for every match')
ensure
  service&.close
end
puts 'PASS ordinary read budget: 24 bound matches in at most four document reads, read-only results and no duplicate table on reopening'
