require 'tmpdir'
require_relative '../support/saved_games_ui'
require_relative '../support/tournament_server_plan_table'
T=GameRoomTournaments
Dir.mktmpdir('saved-app-',ENV.fetch('TMPDIR')) do |directory|
  broker=NativeLiveSessionsBroker.new
  app=SaveAppDriver.new(broker)
  $game_room_test_user='Alice'
  game=GameRoomGames::TicTacToe.new
  match={'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}
  candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>game.id,'game_options'=>game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'roster'=>%w[alice bob],'matches'=>[match]}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  service=T::OrdinaryMatchService.new(program:ProgramDouble.new(broker.endpoint('Alice')),registry:GameRoomGames::CATALOG,
    lobby:app.lobby,games:app.games,transport:app.transport,table:docs,
    journal:T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'saved-app'),
    source:-> {{'candidate'=>candidate,'tournament_id'=>5}},user:-> {'Alice'})
  app.instance_variable_set(:@ordinary_tournament_services,{'fixture'=>service})
  app.define_singleton_method(:ordinary_tournament_service){|_|service}
  table=service.open_match(match_id:match['match_id'],leg:1)
  bob=GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Bob')))
  bob.join_room(table,'Bob')
  session=app.games.start_session(table:table,game:game.id,players:%w[Alice Bob],options:JSON.generate(game.default_options),**service.start_parameters(table,players:%w[Alice Bob]))
  assert(app.send(:save_current_game,table,session,game),'App did not save tournament game')
  saved=app.send(:saved_games).fetch(app.send(:saved_games).list.first['id'])
  assert_equal(match['match_id'],saved['tournament']['match_id'])
  resumed_table=app.send(:create_saved_game_table,saved)
  assert(resumed_table,'App did not prepare tournament continuation')
  bob.join_room(resumed_table,'Bob')
  resumed=app.send(:resume_saved_game_at_table,resumed_table,app.room_state(resumed_table))
  assert(resumed,'App did not bind restored tournament session')
  assert(app.send(:saved_games).list.empty?,'Successful binding did not consume saved copy')
  assert_equal(resumed['__id'],service.send(:read_match_binding,candidate,5,match,'alice')['session_id'])
  assert(app.send(:create_saved_game_table,saved).nil?,'Old saved copy created another tournament table')
  assert(app.notices.any?{|notice|notice.is_a?(String) && notice.include?('saved_match_changed')},'Stale save did not explain rejection')
  service.close
end
puts 'PASS app tournament save/restore: private archive marker, native restoration, linked same match before save consumption, old-copy rejection'
