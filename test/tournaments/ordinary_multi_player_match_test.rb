require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
[3,4,8].each do |count|
  Dir.mktmpdir('ordinary-many-',ENV.fetch('TMPDIR')) do |directory|
    users=%w[Alice Bob Carol Dave Eve Frank Grace Heidi].first(count)
    game=GameRoomGames::Farkle.new
    options=game.normalize_options(game.default_options.merge('score_limit'=>1,'turn_minimum'=>1,'entry_minimum'=>1))
    h=NativeRoomHarness.new(game:game,users:users,options:options)
    programs=users.to_h{|user|[user,ProgramDouble.new(h.broker.endpoint(user))]}
    lobbies=users.to_h{|user|[user,LobbyRepository.new(programs[user],transport:h.transports[user],server_tables:Object.new)]}
    h.as('Alice'){lobbies['Alice'].close_table(h.table)}
    author='Alice'
    docs=TournamentServerPlanTableSupport::Table.new(user:-> {author})
    people=users.map(&:downcase)
    candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>game.id,
      'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'format'=>'round_robin','players_per_match'=>count,
      'game_options'=>options,'roster'=>people,'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>people}]}
    source=-> {{'candidate'=>candidate,'tournament_id'=>5}}
    journal=->(user){T::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'native-multi-ordinary')}
    services=users.to_h do |user|
      [user,T::OrdinaryMatchService.new(program:programs[user],registry:GameRoomGames::CATALOG,lobby:lobbies[user],games:h.repositories[user],
        transport:h.transports[user],table:docs,journal:journal.call(user),source:source,user:-> {user})]
    end
    runner=nil
    begin
      table=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
      h.instance_variable_set(:@table,table)
      users.drop(1).each do |user|
        joined=h.as(user){services[user].open_match(match_id:'d'*64,leg:1)}
        assert_equal(table['__live_session_id'],joined['__live_session_id'])
      end
      assert_raises(T::OrdinaryMatchService::Blocked){services['Alice'].start_parameters(table,players:users.drop(1))}
      ordered=services['Alice'].start_parameters(table,players:users.reverse,options:options)
      assert_equal(users,ordered[:players],'Start followed arrival order instead of planned seats')
      h.as('Alice') do
        session=h.repositories['Alice'].start_session(table:table,game:game.id,options:JSON.generate(options),**ordered)
        h.instance_variable_set(:@session,session)
      end
      context=GameRoomGames::ActionContext.new(random_source:GameRoomRandom::LocalSecureSource.new)
      runner=h.as('Alice') do
        GameRoomSessionRunner.new(program:programs['Alice'],transport:h.transports['Alice'],repository:h.repositories['Alice'],
          game:game,session:h.session,table:table,owner:'Alice',viewer:'Alice',room_snapshot_provider:-> {lobbies['Alice'].snapshot_for(table)},
          covered:-> {true},context:context,completion_observer:->(session,replay,events){services['Alice'].observe(table,session,replay,events)})
      end
      256.times do
        step(h,runner)
        replay=h.replay('Alice')
        break if replay.finished?
        actor=replay.current_player
        own=h.replay(actor)
        actions=game.legal_actions(own,actor)
        action=actions.find{|value|value['action']=='bank'} || actions.find{|value|value['action']=='keep'} || actions.first
        h.submit(actor,action,context:context)
      end
      assert(h.replay('Alice').finished?,'Native multiplayer game did not finish')
      step(h,runner)
      deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+5
      view=nil
      loop do
        raise error if (error=services['Alice'].take_error)
        view=services[users.last].result_view
        break if view['results'].size==1
        raise 'Native multiplayer receipt did not arrive' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
        sleep 0.01
      end
      summary=view['results'].first['summary']
      assert_equal(people.sort,summary['participants'])
      assert_equal(people.sort,summary['scores'].keys.sort)
      view['standings'].each do |row|
        score=summary['scores'].fetch(row['unit'])
        expected=2*summary['scores'].values.count{|other|other<score}+summary['scores'].values.count(score)-1
        assert_equal(expected,row['points'])
        assert_equal(1,row['played'])
      end
      assert_equal(count*(count-1),view['standings'].sum{|row|row['points']})
      cold=T::OrdinaryMatchService.new(program:programs[users.last],registry:GameRoomGames::CATALOG,lobby:lobbies[users.last],
        games:h.repositories[users.last],transport:h.transports[users.last],table:docs,journal:journal.call(users.last),source:source,user:-> {users.last})
      begin
        assert_equal(view,cold.result_view,'Cold reader disagrees with multiplayer result')
        retained=JSON.parse(JSON.generate(docs.rows))
        receipt=view['results'].first
        mutations=[
          ->(value){value['summary']['winners']=['outsider'];value['summary']['draw']=false},
          ->(value){value['summary']['participants']=people.sort.drop(1)},
          ->(value){value['summary']['scores'].delete(people.first)},
          ->(value){value['summary']['event_count']=-1},
          ->(value){value['summary']['draw']=true;value['summary']['winners']=[people.first]}
        ]
        mutations.each do |mutate|
          altered=JSON.parse(JSON.generate(receipt))
          mutate.call(altered)
          anchor=services['Alice'].send(:anchor,candidate,5,candidate['matches'].first,'result')
          docs.rows.replace(retained.reject{|row|row['operation_key']==anchor['operation_key']})
          T::ServerPlanDocument.encode(altered,anchor:anchor).each{|row|docs.insert(row)}
          failure=assert_raises(T::OrdinaryMatchService::Blocked){cold.result_view}
          assert_equal(:invalid_result_receipt,failure.code,'Invalid result reached tournament standings')
          docs.rows.replace(JSON.parse(JSON.generate(retained)))
          assert_equal(view,cold.result_view,'Rejected result damaged the retained valid standings')
        end
      ensure
        cold.close
      end
      assert_equal(nil,services['Alice'].observe(table,h.session,h.replay('Alice'),h.events('Alice')),'Completed multiplayer match was collected twice')
    ensure
      runner&.close
      services.each_value(&:close)
    end
  end
end
puts 'PASS native 3/4/8-player ordinary tournament matches: declared counts, one table, planned seats, real game executor, pairwise points and cold reader without duplicate collection'
