require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/temporary_directory'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
require_relative '../../lib/tournaments/server_match_window'
include GameRoomTest::Assertions

GameRoomTest::TemporaryDirectory.create('playing-hours-rejoin-') do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
  documents=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  start=Time.utc(2026,10,21,12).to_i
  now=start+60
  candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>h.game.id,'game_options'=>h.game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'hours'},
    'starts_at'=>start,'windows'=>[],'daily_hours'=>{'start'=>'12:00','end'=>'12:02','utc_offset_minutes'=>0},
    'roster'=>%w[alice bob],'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]},
      {'match_id'=>'e'*64,'leg'=>2,'number'=>2,'players'=>%w[alice bob]}]}
  original=Marshal.dump(candidate)
  programs={};lobbies={};services={}
  %w[Alice Bob].each do |user|
    programs[user]=ProgramDouble.new(h.broker.endpoint(user))
    lobbies[user]=LobbyRepository.new(programs[user],transport:h.transports[user],server_tables:Object.new)
    services[user]=GameRoomTournaments::OrdinaryMatchService.new(program:programs[user],registry:GameRoomGames::CATALOG,
      lobby:lobbies[user],games:h.repositories[user],transport:h.transports[user],table:documents.for_user(user),
      journal:GameRoomTournaments::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'hours-test'),
      source:-> {{'candidate'=>candidate,'tournament_id'=>1}},user:-> {user},
      entry_guard:->(current,_,_){GameRoomTournaments::ServerMatchWindow.current(current,now)})
  end
  h.as('Alice'){lobbies['Alice'].close_table(h.table)}
  table=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
  now=start+120
  before=Marshal.dump(documents.rows)
  error=assert_raises(GameRoomTournaments::Publication::Invalid) do
    h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  end
  assert_equal(:outside_window,error.code)
  assert_equal(nil,lobbies['Bob'].current_table_for('Bob'),'Inspection retained unstarted membership')
  assert_equal(before,Marshal.dump(documents.rows),'Inspection wrote a tournament document')
  error=assert_raises(GameRoomTournaments::Publication::Invalid) do
    h.as('Alice'){services['Alice'].start_parameters(table,players:%w[Alice Bob])}
  end
  assert_equal(:outside_window,error.code)
  now=start+119
  h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  h.as('Alice') do
    parameters=services['Alice'].start_parameters(table,players:%w[Alice Bob])
    h.repositories['Alice'].start_session(table:table,game:h.game.id,options:JSON.generate(h.game.default_options),**parameters)
  end
  now=start+120
  before=Marshal.dump(documents.rows)
  h.as('Bob') do
    lobbies['Bob'].leave_table(table,'Bob')
    assert_equal([],h.transports['Bob'].game_sessions(table,force:true),'Departed account still has history access')
    returned=services['Bob'].open_match(match_id:'d'*64,leg:1)
    assert_equal(table['__live_session_id'],returned['__live_session_id'])
  end
  assert_equal(before,Marshal.dump(documents.rows),'Return changed tournament records')
  error=assert_raises(GameRoomTournaments::Publication::Invalid) do
    h.as('Alice'){services['Alice'].open_match(match_id:'e'*64,leg:2)}
  end
  assert_equal(:outside_window,error.code)
  assert_equal(before,Marshal.dump(documents.rows),'New table attempt wrote tournament records')
  assert_equal(original,Marshal.dump(candidate),'Return changed match identities or settings')
ensure
  services&.each_value(&:close)
end
puts 'PASS playing hours: unstarted entry/start refused; actual departure/rejoin to the same started game allowed; new matches still refused'
