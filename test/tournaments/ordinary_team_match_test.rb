require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('ordinary-teams-',ENV.fetch('TMPDIR')) do |directory|
  users=%w[Alice Bob Carol Dave]
  game=GameRoomGames::Domino.new
  options=game.normalize_options(game.default_options.merge('teams'=>true,'team_count'=>'2','score_limit'=>1))
  h=NativeRoomHarness.new(game:game,users:users,options:options)
  programs=users.to_h{|user|[user,ProgramDouble.new(h.broker.endpoint(user))]}
  lobbies=users.to_h{|user|[user,LobbyRepository.new(programs[user],transport:h.transports[user],server_tables:Object.new)]}
  h.as('Alice'){lobbies['Alice'].close_table(h.table)}
  author='Alice'
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {author})
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>game.id,
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'format'=>'round_robin','players_per_match'=>4,
    'game_options'=>options,'roster'=>users.map(&:downcase),'team_template'=>[0,1,0,1],
    'membership'=>{'version'=>1,'kind'=>'fixed-teams','units'=>[
      {'unit_id'=>'red','accounts'=>%w[alice bob]},{'unit_id'=>'blue','accounts'=>%w[carol dave]}]},
    'matches'=>[1,2].map{|leg|{'match_id'=>leg.to_s*64,'leg'=>leg,'number'=>leg,'players'=>users.map(&:downcase),'unit_ids'=>%w[red blue]}}}
  source=-> {{'candidate'=>candidate,'tournament_id'=>5}}
  journal=->(user){T::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'native-team-ordinary')}
  services=users.to_h{|user|[user,T::OrdinaryMatchService.new(program:programs[user],registry:GameRoomGames::CATALOG,lobby:lobbies[user],games:h.repositories[user],
    transport:h.transports[user],table:docs,journal:journal.call(user),source:source,user:-> {user})]}
  begin
    [1,2].each do |leg|
      creator=leg==1 ? 'Alice' : 'Carol'
      author=creator
      match=candidate['matches'][leg-1]
      table=h.as(creator){services[creator].open_match(match_id:match['match_id'],leg:leg)}
      h.instance_variable_set(:@table,table)
      (users-[creator]).each{|user|h.as(user){services[user].open_match(match_id:match['match_id'],leg:leg)}}
      native=JSON.parse(table['game_options'])
      wrong_options=native.merge('team_seats'=>[0,0,1,1])
      assert_raises(T::OrdinaryMatchService::Blocked){services[creator].start_parameters(table,players:users,options:wrong_options)}
      assert_raises(T::OrdinaryMatchService::Blocked){services[creator].start_parameters(table,players:%w[Alice Bob Carol Eve],options:native)}
      parameters=services[creator].start_parameters(table,players:users.reverse,options:native)
      expected=leg==1 ? %w[Alice Carol Bob Dave] : %w[Carol Alice Dave Bob]
      assert_equal(expected,parameters[:players],'Team return seats were not swapped')
      h.as(creator) do
        session=h.repositories[creator].start_session(table:table,game:game.id,players:users,options:JSON.generate(native),**parameters)
        h.instance_variable_set(:@session,session)
      end
      lost_ack=ENV['TEST_LOST_ACK']=='1' && leg==1
      recovered=false
      if lost_ack
        target=services[creator].send(:anchor,candidate,5,match,'result')['operation_key']
        docs.on_insert=->(row){raise IOError,'Team result saved but reply lost' if row['operation_key']==target && row['part_index']==row['part_count']}
      end
      contexts=users.to_h{|user|[user,GameRoomGames::ActionContext.new(hidden_submissions:HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),random_source:GameRoomRandom::LocalSecureSource.new)]}
      runners=users.to_h do |user|
        [user,h.as(user){GameRoomSessionRunner.new(program:programs[user],transport:h.transports[user],repository:h.repositories[user],game:game,
          session:h.session,table:table,owner:creator,viewer:user,room_snapshot_provider:-> {lobbies[user].snapshot_for(table)},covered:-> {true},context:contexts[user],
          completion_observer:->(session,replay,events){services[user].observe(table,session,replay,events)})}]
      end
      begin
        512.times do
          runners.each{|user,runner|step(h,runner,user)}
          replay=h.replay(creator)
          break if replay.finished?
          actor=replay.current_player
          actions=game.legal_actions(h.replay(actor),actor)
          selected=actions.find{|action|action['action']=='play'} || actions.first
          h.submit(actor,selected,context:contexts[actor]) if selected
        end
        assert(h.replay(creator).finished?,'Native team game did not finish')
        runners.each{|user,runner|step(h,runner,user)}
        deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+5
        view=nil
        loop do
          services.each_value do |service|
            error=service.take_error
            next unless error
            raise error unless lost_ack && error.is_a?(IOError) && error.message=='Team result saved but reply lost'
            record=services[creator].operations.find{|operation|JSON.parse(operation['values']['document_json'])['kind']=='ordinary-match-result-v1'}
            assert_equal('attempted',record['status'])
            before=docs.insert_count
            docs.on_insert=nil
            recovery=T::OrdinaryMatchService.new(program:programs[creator],registry:GameRoomGames::CATALOG,lobby:lobbies[creator],games:h.repositories[creator],
              transport:h.transports[creator],table:docs,journal:journal.call(creator),source:source,user:-> {creator})
            begin
              assert_equal('confirmed',recovery.reconcile(record['id'])['status'])
              assert_equal(before,docs.insert_count,'Uncertain team result was resent')
              recovered=true
            ensure
              recovery.close
            end
          end
          view=services['Dave'].result_view
          break if view['results'].size==leg && (!lost_ack || recovered)
          raise 'Team result receipt missing' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
          sleep 0.01
        end
        assert_equal(%w[blue red],view['results'].last['summary']['participants'])
        assert_equal(%w[blue red],view['standings'].map{|row|row['unit']}.sort)
        assert(view['standings'].all?{|row|row['played']==leg})
        cold=T::OrdinaryMatchService.new(program:programs['Dave'],registry:GameRoomGames::CATALOG,lobby:lobbies['Dave'],games:h.repositories['Dave'],
          transport:h.transports['Dave'],table:docs,journal:journal.call('Dave'),source:source,user:-> {'Dave'})
        begin
          assert_equal(view,cold.result_view,'Cold client lost team standings')
          retained=JSON.parse(JSON.generate(docs.rows))
          altered=JSON.parse(JSON.generate(view['results'].find{|receipt|receipt['leg']==leg}))
          altered['summary']['winners']=['alice']
          altered['summary']['draw']=false
          anchor=services[creator].send(:anchor,candidate,5,match,'result')
          docs.rows.replace(retained.reject{|row|row['operation_key']==anchor['operation_key']})
          T::ServerPlanDocument.encode(altered,anchor:anchor).each{|row|docs.insert(row)}
          failure=assert_raises(T::OrdinaryMatchService::Blocked){cold.result_view}
          assert_equal(:invalid_result_receipt,failure.code,'Individual winner was counted as a team result')
          docs.rows.replace(retained)
          assert_equal(view,cold.result_view)
          original=candidate['roster_generation']
          docs.on_select=-> {candidate['roster_generation']='f'*64}
          assert_raises(T::OrdinaryMatchService::Blocked){cold.result_view}
          candidate['roster_generation']=original
          docs.on_select=nil
          assert_equal(view,cold.result_view)
        ensure
          cold.close
        end
      ensure
        runners.each_value(&:close)
      end
      users.each{|user|h.as(user){lobbies[user].leave_table(table,user)} unless user==creator}
      h.as(creator){lobbies[creator].close_table(table)}
    end
  ensure
    services.each_value(&:close)
  end
end
puts 'PASS ordinary team workflow: four native clients, one bound table, swapped return sides/creator, real finished games, authenticated team receipts, small scores and cold shared standings'
