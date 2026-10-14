require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
require_relative '../../lib/tournaments/server_phase_store'
T=GameRoomTournaments
Dir.mktmpdir('server-phase-native-',ENV.fetch('TMPDIR')) do |directory|
  teams=ENV['TEST_TEAMS']=='1'
  wildcard=ENV['TEST_WILDCARD']=='1'
  direct=ENV['TEST_DIRECT_FINAL']=='1'
  users=teams ? %w[Alice Bob Carol Dave Eve Frank Grace Heidi] : direct ? %w[Alice Bob] : wildcard ? %w[Alice Bob Carol Dave Eve Frank Grace Heidi Ivan] : %w[Alice Bob Carol Dave]
  game=teams ? GameRoomGames::Domino.new : GameRoomGames::TicTacToe.new
  options=teams ? game.normalize_options(game.default_options.merge('teams'=>true,'team_count'=>'2','score_limit'=>1)) : game.default_options
  h=NativeRoomHarness.new(game:game,users:users.first(4),options:options)
  users.drop(4).each{|user|h.add_client(user)}
  programs=users.to_h{|user|[user,ProgramDouble.new(h.broker.endpoint(user))]}
  lobbies=users.to_h{|user|[user,LobbyRepository.new(programs[user],transport:h.transports[user],server_tables:Object.new)]}
  h.as('Alice'){lobbies['Alice'].close_table(h.table)}
  author='Alice'
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {author})
  settings={'group_advancement'=>T::GroupAdvancement::COMPACT,'pairing'=>'all_combinations','rematch'=>false}
  membership=teams ? {'version'=>1,'kind'=>'fixed-teams','units'=>users.each_slice(2).with_index.map{|pair,index|{'unit_id'=>"team-#{index+1}",'accounts'=>pair.map(&:downcase)}}} : nil
  units=membership ? membership['units'].map{|unit|unit['unit_id']} : users.map(&:downcase)
  matches,groups=direct ? [[],[]] : T::GroupSchedule.build(roster:units,settings:settings,players_per_match:2)
  matches=matches.each_with_index.map{|match,index|match.merge('match_id'=>(index+1).to_s*64)}
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>game.id,
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'format'=>'groups_knockout','players_per_match'=>2,
    'game_options'=>options,'roster'=>users.map(&:downcase),'groups'=>T::GroupSchedule.metadata(groups,matches),'matches'=>matches,
    'group_advancement'=>T::GroupAdvancement::COMPACT,'state'=>'observed_candidate','finality'=>'unknown','start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false}
  if teams
    candidate.merge!('membership'=>membership,'team_template'=>[0,1,0,1],'players_per_match'=>4)
    matches.each do |match|
      match['unit_ids']=match['players']
      match['players']=match['unit_ids'].flat_map{|id|membership['units'].find{|unit|unit['unit_id']==id}['accounts']}
    end
  end
  series=ENV['TEST_SERIES']=='1'
  group_draw=ENV['TEST_GROUP_DRAW']=='1'
  extra_draw=ENV['TEST_EXTRA_DRAW']=='1'
  candidate['final_wins_to']=2 if series
  if direct
    metadata=T::KnockoutSchedule.direct_metadata(seeds:units,generation:candidate['roster_generation'],publication_digest:candidate['publication_digest'],target:series ? 2 : nil)
    candidate.merge!('format'=>'knockout','knockout'=>metadata)
    candidate['schedule_id'],candidate['matches']=T::KnockoutSchedule.matches(metadata:metadata,generation:candidate['roster_generation'])
    candidate.delete('groups')
    candidate.delete('group_advancement')
  end
  root=-> {{'candidate'=>candidate,'tournament_id'=>5}}
  ordinary_journal=->(user){T::OperationJournal.new(directory:File.join(directory,'ordinary',user),owner:user.downcase,backend_identity:'ordinary-native-phase')}
  reader=->(phase,original) do
    service=T::OrdinaryMatchService.new(program:programs['Alice'],registry:GameRoomGames::CATALOG,lobby:nil,games:nil,transport:nil,
      table:docs,journal:ordinary_journal.call('Alice'),source:-> {original.merge('candidate'=>phase)},user:-> {'Alice'})
    begin;service.result_view;ensure;service.close;end
  end
  store_for=->(user){T::ServerPhaseStore.new(table:docs,journal:T::OperationJournal.new(directory:File.join(directory,'phases',user),owner:user.downcase,backend_identity:'native-phase-store'),user:-> {user},source:root,results:reader)}
  store=store_for.call('Alice')
  failure=assert_raises(T::Publication::Invalid){store.advance(expected_schedule_id:candidate['schedule_id'])}
  assert_equal(:phase_results_incomplete,failure.code)
  assert_equal(0,docs.insert_count)
  completed=false
  limit=(series ? 4 : 3)+(group_draw ? 1 : 0)+(extra_draw ? 1 : 0)+((teams || wildcard) ? 8 : 0)
  limit.times do |phase_index|
    current=store.current
    phase=current['candidate']
    assert_equal(phase_index==0 && !direct ? 'groups_knockout' : 'knockout',phase['format'])
    phase['matches'].each_with_index do |match,match_index|
      actors=T::MatchOrder.players(phase['matches'],match).map{|account|users.find{|user|user.downcase==account}}
      prepared=teams ? T::OrdinaryTeamPlayers.prepare(candidate:phase,match:match,registry:GameRoomGames::CATALOG) : nil
      creator=prepared ? users.find{|user|user.downcase==prepared['players'].first['account']} : actors.first
      author=creator
      services=actors.to_h{|user|[user,T::OrdinaryMatchService.new(program:programs[user],registry:GameRoomGames::CATALOG,lobby:lobbies[user],games:h.repositories[user],transport:h.transports[user],
        table:docs,journal:ordinary_journal.call(user),source:-> {store.current},user:-> {user})]}
      runners={}
      begin
        table=h.as(creator){services[creator].open_match(match_id:match['match_id'],leg:match['leg'])}
        h.instance_variable_set(:@table,table)
        (actors-[creator]).each{|user|h.as(user){services[user].open_match(match_id:match['match_id'],leg:match['leg'])}}
        parameters=services[creator].start_parameters(table,players:actors.reverse,options:JSON.parse(table['game_options']))
        h.as(creator){h.instance_variable_set(:@session,h.repositories[creator].start_session(table:table,game:game.id,players:actors,options:JSON.generate(phase['game_options']),**parameters))}
        contexts=actors.to_h{|user|[user,GameRoomGames::ActionContext.new(hidden_submissions:HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),random_source:GameRoomRandom::LocalSecureSource.new)]}
        runners=actors.to_h do |user|
          [user,h.as(user){GameRoomSessionRunner.new(program:programs[user],transport:h.transports[user],repository:h.repositories[user],game:game,session:h.session,table:table,owner:creator,viewer:user,
            room_snapshot_provider:-> {lobbies[user].snapshot_for(table)},covered:-> {true},context:contexts[user],
            completion_observer:->(session,replay,events){services[user].observe(table,session,replay,events)})}]
        end
        move_index=0
        draw_moves=[[0,0],[1,1],[2,2],[0,2],[2,0],[1,0],[1,2],[2,1],[0,1]]
        512.times do
          runners.each{|user,runner|step(h,runner,user)}
          replay=h.replay(creator)
          break if replay.finished?
          actor=replay.current_player
          actions=game.legal_actions(h.replay(actor),actor)
          selected=actions.find{|action|action['action']=='play'} || actions.first
          draw_fixture=(group_draw && phase_index==0 || extra_draw && phase_index==1 && phase.dig('knockout','qualification')) && match_index==0
          if draw_fixture && !teams
            x,y=draw_moves.fetch(move_index)
            selected=actions.find{|action|action['x']==x && action['y']==y}
            raise 'Planned legal draw move missing' unless selected
            move_index+=1
          end
          h.submit(actor,selected,context:contexts[actor]) if selected
        end
        runners.each{|user,runner|step(h,runner,user)}
        assert(h.replay(creator).finished?,'Native phase fixture did not finish')
        deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+5
        loop do
          raise error if (error=services[creator].take_error)
          begin
            break if reader.call(phase,current)['results'].any?{|receipt|receipt['match_id']==match['match_id']}
          rescue T::Publication::Invalid=>error
            raise unless error.code==:incomplete_plan_document
          end
          raise 'Phase receipt missing' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
          sleep 0.01
        end
        (actors-[creator]).each{|user|h.as(user){lobbies[user].leave_table(table,user)}}
        h.as(creator){lobbies[creator].close_table(table)}
      ensure
        runners.each_value(&:close)
        services.each_value(&:close)
      end
    end
    author='Alice'
    final_view=reader.call(phase,current)
    if final_view['knockout_state']!='completed'
      before=docs.insert_count
      assert_raises(T::Publication::Invalid){store_for.call('Bob').advance(expected_schedule_id:phase['schedule_id'])}
      assert_equal(before,docs.insert_count,'Non-organizer published a phase')
      next_phase=store.advance(expected_schedule_id:phase['schedule_id'])
      assert(next_phase['candidate'].dig('knockout','qualification'),'Group draw did not create qualification games') if group_draw && phase_index==0
      if wildcard && phase_index==0
        tasks=next_phase['candidate']['knockout']['qualification']['tasks']
        assert(tasks.any?{|task|task['group'].nil? && task['units'].size==3},'Nine-player tie did not schedule the best-second wildcard contest')
      end
      assert_equal(2,next_phase['candidate']['knockout']['qualification']['attempt']) if extra_draw && phase_index==1
      assert_equal(next_phase,store_for.call('Dave').current,'Cold client did not read the next phase')
      assert_equal(phase_index+1,next_phase['phase_history'].size,'Previous phase results disappeared')
      assert_equal(direct ? 'knockout' : 'groups_knockout',next_phase['phase_history'].first['candidate']['format'])
      assert(next_phase['candidate']['matches'].all?{|match|!phase['matches'].any?{|old|old['match_id']==match['match_id']}})
      before=docs.insert_count
      assert_raises(T::Publication::Invalid){store.advance(expected_schedule_id:phase['schedule_id'])}
      assert_equal(before,docs.insert_count,'Old UI token published another phase')
    else
      assert_equal('completed',final_view['knockout_state'])
      assert(final_view['champion'].is_a?(String),'Completed final did not expose its champion')
      failure=assert_raises(T::Publication::Invalid){store.advance(expected_schedule_id:phase['schedule_id'])}
      assert_equal(:tournament_completed,failure.code)
      completed=true
      break
    end
  end
  assert(completed,'Native sporting phases did not reach a completed final')
end
mode=ENV['TEST_DIRECT_FINAL']=='1' ? 'direct final' : ENV['TEST_WILDCARD']=='1' ? 'nine-player wildcard' : ENV['TEST_TEAMS']=='1' ? 'four fixed pairs' : ENV['TEST_GROUP_DRAW']=='1' ? 'drawn group qualification' : 'individual groups'
puts "PASS native shared phase lifecycle (#{mode}): real fixtures, authenticated result lineage, organizer-only publication, cold readers, stale-token blocking and completed tournament"
