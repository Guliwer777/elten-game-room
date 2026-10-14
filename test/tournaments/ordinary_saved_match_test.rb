require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
require_relative '../../lib/saved_game_archive'
T=GameRoomTournaments
class TournamentSaveArchive < GameRoomSavedGameArchive
  def persist(row);row;end
end
Dir.mktmpdir('saved-match-',ENV.fetch('TMPDIR')) do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
  program=ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby=LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
  h.as('Alice'){lobby.close_table(h.table)}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  match={'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}
  candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>h.game.id,'game_options'=>h.game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'roster'=>%w[alice bob],'matches'=>[match]}
  make=->(actor,path) do
    p=ProgramDouble.new(h.broker.endpoint(actor))
    T::OrdinaryMatchService.new(program:p,registry:GameRoomGames::CATALOG,lobby:LobbyRepository.new(p,transport:h.transports[actor],server_tables:Object.new),
      games:h.repositories[actor],transport:h.transports[actor],table:docs,
      journal:T::OperationJournal.new(directory:File.join(directory,path),owner:actor.downcase,backend_identity:'saved-test'),
      source:-> {{'candidate'=>candidate,'tournament_id'=>5}},user:-> {actor})
  end
  creator=make.call('Alice','alice'); guest=make.call('Bob','bob')
  table=h.as('Alice'){creator.open_match(match_id:match['match_id'],leg:1)}
  h.instance_variable_set(:@table,table)
  h.as('Bob'){guest.open_match(match_id:match['match_id'],leg:1)}
  session=h.as('Alice'){h.repositories['Alice'].start_session(table:table,game:h.game.id,players:h.users,options:JSON.generate(h.game.default_options),**creator.start_parameters(table,players:h.users))}
  h.instance_variable_set(:@session,session)
  replay=h.replay('Alice');h.submit(replay.current_player,h.game.legal_actions(replay,replay.current_player).first)
  archive=TournamentSaveArchive.new(program,owner:'Alice')
  marker=creator.saved_match_reference(table,session)
  saved=h.as('Alice'){archive.put(game:h.game,table:table,snapshot:h.repositories['Alice'].snapshot_for(session,force_events:true),repository:h.repositories['Alice'],tournament:marker)}
  assert_equal(match['match_id'],saved['tournament']['match_id'])
  h.as('Alice'){lobby.close_table(table)}
  guest.result_view(include_match_status:true)
  new_table=h.as('Alice'){lobby.create_table(name:'Saved tournament',game:h.game.id,owner:'Alice',game_options:saved['options'],resume_save_id:saved['id']).table}
  h.transports['Bob'].join_room(new_table,'Bob')
  restoration=archive.restored_data(saved,game:h.game,table_id:new_table['__id'])
  resumed=h.as('Alice'){h.repositories['Alice'].restore_session(table:new_table,game:h.game.id,players:restoration[:players],options:saved['options'],restore:restoration)}
  if ENV['TEST_LOST_ACK']=='1'
    docs.on_insert=->(row){raise IOError,'lost continuation reply' if row['part_index']==row['part_count']}
    assert_raises(IOError){h.as('Alice'){creator.bind_resumed_match(saved,new_table,resumed)}}
    docs.on_insert=nil
    operation=creator.operations.find{|row|JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-continuation-v1'}
    before=docs.insert_count
    creator.reconcile(operation['id'])
    assert_equal(before,docs.insert_count,'Continuation recovery retried a write')
  end
  binding=h.as('Alice'){creator.bind_resumed_match(saved,new_table,resumed)}
  assert_equal(resumed['__id'],binding['session_id'])
  assert_equal(new_table['__id'],guest.send(:read_match_binding,candidate,5,match,'alice')['table']['__id'])
  assert_raises(T::OrdinaryMatchService::Blocked){creator.check_saved_match(saved)}
  h.instance_variable_set(:@table,new_table);h.instance_variable_set(:@session,resumed)
  if ENV['TEST_CANCEL_RESUME']=='1'
    creator.award_forfeit(match_id:match['match_id'],leg:1,winner:'bob',expected_schedule_id:candidate['schedule_id'],cancel_started:true)
    assert_raises(T::OrdinaryMatchService::Blocked){creator.check_saved_match(saved,allow_linked:true)}
  end
  12.times do
    replay=h.replay('Alice');break if replay.finished?
    actor=replay.current_player;h.submit(actor,h.game.legal_actions(replay,actor).first)
  end
  assert(h.replay('Alice').finished?,'Resumed game did not finish')
  creator.collect(creator.instance_variable_get(:@bindings)[new_table['__id']])
  view=guest.result_view
  assert_equal(1,view['results'].size)
  assert_equal(match['match_id'],view['results'].first['match_id'])
  cold=make.call('Bob','cold')
  assert_equal(view,cold.result_view,'Cold client lost saved-match lineage')
  assert_raises(T::OrdinaryMatchService::Blocked){creator.check_saved_match(saved)}
  count=docs.insert_count
  operation=creator.operations.find{|row|JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-continuation-v1'}
  creator.reconcile(operation['id'])
  assert_equal(count,docs.insert_count)
  [creator,guest,cold].each(&:close)
end
puts 'PASS native tournament save continuation: same fixture after new native room, authentic restored history, shared result and cold second client, consumed-old-save guard'
