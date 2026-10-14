require_relative '../support/session_runner'
require_relative '../../games/catalog'
require_relative '../../tools/tournaments/ordinary_table_result_probe'
require_relative '../../lib/tournaments/standings_ranking'
T = GameRoomTournaments
h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
h.start
binding = {'schedule_id'=>'test-schedule','match_id'=>'match-1','leg'=>1,'table_id'=>h.table['__id'],
  'native_session_id'=>h.table['__live_session_id'], 'session_id'=>h.session['__id'], 'game_id'=>h.game.id,
  'options'=>h.game.default_options, 'players'=>h.users.map{|name|{'account'=>name.downcase,'username'=>name,'seat'=>h.users.index(name)}}}
read = ->(user, value=binding) { h.as(user) { T::OrdinaryTableResultProbe.read(repository:h.repositories.fetch(user),
  registry:GameRoomGames::CATALOG, table:h.table, binding:value) } }
assert_equal(nil,read.call('Alice'))
results=[]
program=ProgramDouble.new(h.broker.endpoint('Alice'))
lobby=LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
runner=h.as('Alice') do
  GameRoomSessionRunner.new(program:program,transport:h.transports['Alice'],repository:h.repositories['Alice'],
    game:h.game,session:h.session,table:h.table,owner:'Alice',viewer:'Alice',
    room_snapshot_provider:-> {lobby.snapshot_for(h.table)}, covered:-> {true},
    context:GameRoomGames::ActionContext.new(random_source:GameRoomRandom::LocalSecureSource.new),
    statistics_observer:->(session,replay) { results << read.call('Alice') if session['__id']==binding['session_id'] && replay.finished? })
end
begin
  step(h,runner)
  12.times do
    replay=h.replay('Alice')
    break if replay.finished?
    actor=replay.current_player
    h.submit(actor,h.game.legal_actions(replay,actor).first)
    step(h,runner)
  end
  assert(h.replay('Alice').finished?,'Ordinary table did not complete')
  assert(!results.empty?,'Runner did not automatically collect the result')
  result=results.last
  assert_equal(result,read.call('Bob'))
  assert_equal(h.replay('Alice').accepted_events.size,result['summary']['event_count'])
  table=T::StandingsRanking.calculate(units:%w[alice bob],results:[result['summary'].slice('participants','winners','scores','score_order').merge('id'=>'match-1')],
    points:T::Standings::MATCH_POINTS,criteria:T::StandingsRanking::CRITERIA)
  assert_equal([0,2],table.map{|row|row['points']}.sort)
  # Same names and game in a rematch must not silently count as the first leg.
  other=binding.merge('session_id'=>binding['session_id']+100000)
  assert_raises(T::Publication::Invalid){read.call('Alice',other)}
  assert_raises(T::Publication::Invalid){read.call('Alice',binding.merge('table_id'=>binding['table_id']+1))}
  assert_raises(T::Publication::Invalid){read.call('Alice',binding.merge('players'=>[binding['players'].first,{'account'=>'other','username'=>'Other','seat'=>1}]))}
  snapshot=h.repositories['Alice'].snapshot_for(h.session)
  broken=Object.new
  broken.define_singleton_method(:session_by_id){|*args,**options|h.repositories['Alice'].session_by_id(*args,**options)}
  broken.define_singleton_method(:snapshot_for){|*_,**_|GameRoomSessionContracts::GameSnapshot.new(session:snapshot.session,events:snapshot.events+[{'__id'=>999999,'action'=>'invalid','actor'=>'Nobody','data'=>'{}'}])}
  [:session_id,:players_for,:actor_of,:event_id].each{|method|broken.define_singleton_method(method){|*args|h.repositories['Alice'].public_send(method,*args)}}
  assert_raises(T::Publication::Invalid) do
    T::OrdinaryTableResultProbe.read(repository:broken,registry:GameRoomGames::CATALOG,table:h.table,binding:binding)
  end
ensure
  runner.close
end
puts 'PASS ordinary table automatic completion: runner callback, both-client replay/result agreement, 2/0 points and wrong table/session/players refusal'
