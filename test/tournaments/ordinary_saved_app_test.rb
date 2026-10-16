require 'tmpdir'
require_relative '../support/saved_games_ui'
require_relative '../support/invitation_fresh_endpoint'
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
  guest_apps={}; guest_services={}
  %w[Bob Carol Dave].each do |user|
    guest=guest_apps[user]=InvitationAppDriver.new(broker,user,DurableNoticeGateway.new)
    guest_services[user]=T::OrdinaryMatchService.new(program:guest,registry:GameRoomGames::CATALOG,
      lobby:guest.instance_variable_get(:@lobby),games:guest.instance_variable_get(:@games),transport:guest.transport,
      table:docs.for_user(user),journal:T::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'saved-app'),
      source:-> {{'candidate'=>candidate,'tournament_id'=>5}},user:-> {user})
    guest.instance_variable_set(:@ordinary_tournament_services,{JSON.generate(candidate['publication_ref'])=>guest_services[user]})
  end
  table=service.open_match(match_id:match['match_id'],leg:1)
  bob=GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Bob')))
  bob.join_room(table,'Bob')
  session=app.games.start_session(table:table,game:game.id,players:%w[Alice Bob],options:JSON.generate(game.default_options),**service.start_parameters(table,players:%w[Alice Bob]))
  $game_room_test_user='Carol'
  guest_apps['Carol'].send(:join_table_snapshot,LobbyRepository::TableSnapshot.new(table:table,members:%w[Alice Bob]))
  assert(guest_apps['Carol'].instance_variable_get(:@lobby).snapshot_for(table).observer?('Carol'))
  $game_room_test_user='Alice'
  assert(app.send(:save_current_game,table,session,game),'App did not save tournament game')
  saved=app.send(:saved_games).fetch(app.send(:saved_games).list.first['id'])
  assert_equal(%w[Alice Bob],saved['players'],'Save retained an observer as a player')
  assert_equal(match['match_id'],saved['tournament']['match_id'])
  if ENV['TEST_PREPARE_LOST_ACK']=='1'
    docs.on_insert=->(row){raise EltenAPI::LiveSessions::TimeoutError,'lost prepared continuation reply' if row['part_index']==row['part_count']}
    assert(app.send(:create_saved_game_table,saved).nil?,'Lost preparation acknowledgement reported success')
    docs.on_insert=nil
    resumed_table=app.lobby.current_table_for('Alice')
    assert(resumed_table,'Lost acknowledgement discarded the already created room')
    assert(!app.send(:saved_games).list.empty?,'Preparing a room consumed the save')
    pending=service.operations.find{|row|JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-continuation-v1'}
    writes_before=docs.insert_count
    service.reconcile(pending.fetch('id'))
    assert_equal(writes_before,docs.insert_count,'Preparation recovery duplicated server rows')
    service.prepare_saved_match(saved,resumed_table)
    app.send(:activate_table_transport,resumed_table)
    app.send(:deliver_table_invitation,resumed_table,'Bob',continuation:true)
  else
    resumed_table=app.send(:create_saved_game_table,saved)
  end
  assert(resumed_table,'App did not prepare tournament continuation')
  assert_equal(table['tournament_match'],resumed_table['tournament_match'],
    'Preparing a saved match lost the tournament marker')
  assert_equal(['Bob'],app.notices.grep(Array).map(&:first).uniq,'Resume invited an old observer')
  writes_before_reopen=docs.insert_count
  assert_equal(resumed_table,app.send(:create_saved_game_table,saved),'Opening the same waiting save did not reuse its room')
  assert_equal(writes_before_reopen,docs.insert_count,'Opening the same save wrote another binding')
  abandoned=resumed_table
  app.lobby.close_table(abandoned)
  assert(!app.send(:saved_games).list.empty?,'Closing a waiting room consumed the save')
  resumed_table=app.send(:create_saved_game_table,saved)
  assert(resumed_table && resumed_table['__id']!=abandoned['__id'],'Could not reopen a closed, never-started saved room')
  %w[Carol Bob].each do |user|
    $game_room_test_user=user
    joined=guest_apps[user].send(:join_table_snapshot,LobbyRepository::TableSnapshot.new(table:resumed_table,members:['Alice']))
    assert(joined&.entered?,"Could not join resumed waiting room: #{user}")
    assert_equal(user=='Carol',guest_apps[user].instance_variable_get(:@lobby).snapshot_for(resumed_table).observer?(user))
  end
  $game_room_test_user='Alice'
  reserved=service.send(:read_match_binding,candidate,5,match,'alice')
  writes=docs.insert_count
  assert_equal(reserved,service.prepare_saved_match(saved,resumed_table),'Repeated preparation changed reserved identities')
  assert_equal(writes,docs.insert_count,'Repeated preparation duplicated a continuation')
  resumed=app.send(:resume_saved_game_at_table,resumed_table,app.room_state(resumed_table))
  assert(resumed,'App did not bind restored tournament session')
  assert(app.send(:saved_games).list.empty?,'Successful binding did not consume saved copy')
  assert_equal(resumed['__id'],service.send(:read_match_binding,candidate,5,match,'alice')['session_id'])
  assert_equal(reserved['session_id'],resumed['__id'],'Restoration ignored the reserved game identity')
  assert_equal(reserved.dig('continuation','archive_id'),resumed['__archive_id'])
  continuation_writes=docs.rows.count{|row|row['operation_key']==service.send(:continuation_anchor,candidate,5,match,reserved)['operation_key']}
  assert_equal(0,continuation_writes,'Native restoration published another continuation')
  $game_room_test_user='Dave'
  assert(guest_apps['Dave'].send(:join_table_snapshot,LobbyRepository::TableSnapshot.new(table:resumed_table,members:%w[Alice Bob Carol])).entered?)
  assert(guest_apps['Dave'].instance_variable_get(:@lobby).snapshot_for(resumed_table).observer?('Dave'))
  $game_room_test_user='Alice'
  assert_equal(%w[Alice Bob],app.lobby.snapshot_for(resumed_table,force:true).game_participants)
  assert(app.send(:create_saved_game_table,saved).nil?,'Old saved copy created another tournament table')
  assert(app.notices.any?{|notice|notice.is_a?(String) && notice.include?('saved_match_changed')},'Stale save did not explain rejection')
  assert(app.send(:save_current_game,resumed_table,resumed,game),'Could not save the continued match again')
  saved_again=app.send(:saved_games).fetch(app.send(:saved_games).list.first.fetch('id'))
  assert_equal(%w[Alice Bob],saved_again['players'],'Saving again retained observers')
  next_table=app.send(:create_saved_game_table,saved_again)
  assert(next_table,'Second continuation could not be prepared')
  bob.join_room(next_table,'Bob')
  next_session=app.send(:resume_saved_game_at_table,next_table,app.room_state(next_table))
  assert(next_session,'Second continuation did not restore')
  final_binding=service.send(:read_match_binding,candidate,5,match,'alice')
  assert_equal(next_session['__id'],final_binding['session_id'],'Second save broke the binding chain')
  assert_equal(match['match_id'],final_binding['match_id'])
  assert(app.send(:saved_games).list.empty?,'Second restoration did not consume its save')
  service.close
  guest_services.each_value(&:close)
end
puts 'PASS app tournament save/restore: private archive marker, native restoration, linked same match before save consumption, old-copy rejection'
