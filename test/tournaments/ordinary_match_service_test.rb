require_relative '../support/temporary_directory'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('ordinary-match-') do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
  program=ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby=LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
  h.as('Alice'){lobby.close_table(h.table)}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>h.game.id,
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'game_options'=>h.game.default_options,'roster'=>%w[alice bob],
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]},
      {'match_id'=>'e'*64,'leg'=>2,'number'=>2,'players'=>%w[alice bob]}]}
  source=-> {{'candidate'=>candidate,'tournament_id'=>5}}
  changes=[]
  journal=->(actor){T::OperationJournal.new(directory:File.join(directory,actor),owner:actor.downcase,backend_identity:'test-ordinary-match')}
  creator=T::OrdinaryMatchService.new(program:program,registry:GameRoomGames::CATALOG,lobby:lobby,games:h.repositories['Alice'],
    transport:h.transports['Alice'],table:docs,journal:journal.call('Alice'),source:source,user:-> {'Alice'},
    changed:->(reference){changes<<reference})
  guest_program=ProgramDouble.new(h.broker.endpoint('Bob'))
  guest_lobby=LobbyRepository.new(guest_program,transport:h.transports['Bob'],server_tables:Object.new)
  guest=T::OrdinaryMatchService.new(program:guest_program,registry:GameRoomGames::CATALOG,lobby:guest_lobby,games:h.repositories['Bob'],
    transport:h.transports['Bob'],table:docs,journal:journal.call('Bob'),source:source,user:-> {'Bob'})
  table=h.as('Alice'){creator.open_match(match_id:'d'*64,leg:1)}
  assert(creator.result_view(include_match_status:true)['forfeitable_matches'].any?{|row|row['match_id']=='d'*64},'Unstarted bound match cannot receive a forfeit')
  h.instance_variable_set(:@table,table)
  h.as('Bob'){guest.open_match(match_id:'d'*64,leg:1)}
  assert_raises(T::OrdinaryMatchService::Blocked){guest.start_parameters(table)}
  assert_raises(T::OrdinaryMatchService::Blocked){creator.start_parameters(table,players:%w[Alice Charlie])}
  h.as('Alice') do
    started=h.repositories['Alice'].start_session(table:table,game:h.game.id,players:h.users,options:JSON.generate(h.game.default_options),**creator.start_parameters(table,players:h.users))
    h.instance_variable_set(:@session,started)
  end
  assert(!creator.result_view(include_match_status:true)['forfeitable_matches'].any?{|row|row['match_id']=='d'*64},'Started native game still offers a forfeit')
  writes=docs.insert_count
  assert_raises(T::OrdinaryMatchService::Blocked) do
    creator.award_forfeit(match_id:'d'*64,leg:1,winner:'alice',expected_schedule_id:candidate['schedule_id'])
  end
  assert_equal(writes,docs.insert_count,'Forfeit wrote over a running native game')
  runner=h.as('Alice') do
    GameRoomSessionRunner.new(program:program,transport:h.transports['Alice'],repository:h.repositories['Alice'],
      game:h.game,session:h.session,table:table,owner:'Alice',viewer:'Alice',room_snapshot_provider:-> {lobby.snapshot_for(table)},covered:-> {true},
      context:GameRoomGames::ActionContext.new(random_source:GameRoomRandom::LocalSecureSource.new),
      completion_observer:->(session,replay,events){creator.observe(table,session,replay,events)})
  end
  lost_ack=ENV['TOURNAMENT_RESULT_LOST_ACK']=='1'
  failed_read=ENV['TOURNAMENT_RESULT_READ_FAILURE']=='1'
  if failed_read
    test_thread=Thread.current
    docs.on_select=-> do
      next if Thread.current==test_thread
      docs.on_select=nil
      raise IOError,'Result read unavailable before publication'
    end
  end
  if lost_ack
    docs.on_insert=->(row){raise IOError,'Result saved but acknowledgement lost' if row['part_index']==row['part_count']}
  end
  begin
    12.times do
      step(h,runner)
      replay=h.replay('Alice')
      break if replay.finished?
      actor=replay.current_player
      h.submit(actor,h.game.legal_actions(replay,actor).first)
    end
    step(h,runner)
    deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+5
    loop do
      error=creator.take_error
      if error
        expected=lost_ack ? 'Result saved but acknowledgement lost' : 'Result read unavailable before publication'
        raise error unless (lost_ack || failed_read) && error.is_a?(IOError) && error.message==expected
        pending=creator.operations.find{|record|JSON.parse(record['values']['document_json'])['kind']=='ordinary-match-result-v1'}
        assert(pending,'Verified terminal result was not retained before network read')
        assert_equal(lost_ack ? 'attempted' : 'prepared',pending.fetch('status'))
        before_recovery=docs.insert_count
        docs.on_insert=nil
        cold_creator=T::OrdinaryMatchService.new(program:program,registry:GameRoomGames::CATALOG,lobby:lobby,games:h.repositories['Alice'],
          transport:h.transports['Alice'],table:docs,journal:journal.call('Alice'),source:source,user:-> {'Alice'},
          changed:->(reference){changes<<reference})
        begin
          assert_equal('confirmed',cold_creator.reconcile(pending.fetch('id')).fetch('status'))
          assert_equal([candidate['publication_ref']],changes,'Result recovery did not wake other views')
          if lost_ack
            assert_equal(before_recovery,docs.insert_count,'Recovery must not send the result again')
          else
            assert(docs.insert_count>before_recovery,'Recovery did not publish the retained result')
            confirmed_writes=docs.insert_count
            cold_creator.reconcile(pending.fetch('id'))
            assert_equal(confirmed_writes,docs.insert_count,'Confirmed recovery duplicated the result')
          end
        ensure
          cold_creator.close
        end
        recovered_lost_ack=true
      end
      view=guest.result_view
      break if view['results'].size==1 && (!(lost_ack || failed_read) || recovered_lost_ack)
      raise 'Automatic result did not arrive' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
      sleep 0.02
    end
    assert_equal([0,2],guest.result_view['standings'].map{|row|row['points']}.sort)
    cold_guest=T::OrdinaryMatchService.new(program:guest_program,registry:GameRoomGames::CATALOG,lobby:guest_lobby,games:h.repositories['Bob'],
      transport:h.transports['Bob'],table:docs,journal:journal.call('Bob'),source:source,user:-> {'Bob'})
    begin
      assert_equal(guest.result_view,cold_guest.result_view,'A fresh client must recover the result without retained bindings')
    ensure
      cold_guest.close
    end
    saved_generation=candidate['roster_generation']
    docs.on_select=-> {candidate['roster_generation']='f'*64}
    assert_raises(T::OrdinaryMatchService::Blocked){guest.result_view}
    candidate['roster_generation']=saved_generation
    docs.on_select=nil
    creation=creator.operations.find{|record|JSON.parse(record['values']['document_json'])['kind']=='ordinary-match-create-v2'}
    insert_before_reconcile=docs.insert_count
    creator.reconcile(creation.fetch('id'))
    assert_equal(insert_before_reconcile,docs.insert_count,'Checking creation must not write or create another table')
    inserted=docs.insert_count
    creator.observe(table,h.session,h.replay('Alice'))
    sleep 0.05
    assert_equal(inserted,docs.insert_count,'Repeated terminal callback duplicated result')
    h.start
    assert_equal(1,guest.result_view['results'].size,'A normal rematch must not silently count as the next tournament leg')
  ensure
    runner.close
    creator.close
    guest.close
  end
end
puts 'PASS ordinary tournament workflow: create, second-client join, normal game executor, automatic server-document result, shared 2/0 standings and no duplicate/rematch counting'
