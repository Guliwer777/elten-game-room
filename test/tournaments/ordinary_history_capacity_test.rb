require_relative '../support/temporary_directory'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/tic_tac_toe'
require_relative '../../games/registry'
require_relative '../../lib/tournaments/ordinary_match_service'

class HistoryCapacityTournamentGame < GameRoomGames::TicTacToe
  def id; 'history_capacity_game'; end
  def session_history_capacity(_options); 32_768; end
end
T = GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('ordinary-history-') do |directory|
  game = HistoryCapacityTournamentGame.new
  h = NativeRoomHarness.new(game:game,users:%w[Alice Bob])
  program = ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby = LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
  h.as('Alice') { lobby.close_table(h.table) }
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>game.id,'game_options'=>game.default_options,'format'=>'round_robin',
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'roster'=>%w[alice bob],
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  service=T::OrdinaryMatchService.new(program:program,registry:GameRoomGames::Registry.new([HistoryCapacityTournamentGame]),
    lobby:lobby,games:h.repositories['Alice'],transport:h.transports['Alice'],table:docs,
    journal:T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'history-capacity'),
    source:-> {{'candidate'=>candidate,'tournament_id'=>1}},user:-> {'Alice'})
  table=h.as('Alice') { service.open_match(match_id:'d'*64,leg:1) }
  core=h.broker.cores.fetch(table['__live_session_id'])
  assert_equal(32_768,core.stack_entries,'Tournament creation ignored the shared game history declaration')
ensure
  service&.close
end
puts 'PASS tournament tables use the same declared native history capacity as ordinary and restored tables'
