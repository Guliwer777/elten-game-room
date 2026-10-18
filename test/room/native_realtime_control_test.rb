require_relative "../support/native_live_sessions"
require_relative "../../games/axel_pong"
require_relative "../../games/audio_ball"
[GameRoomGames::AxelPong.new,GameRoomGames::AudioBall.new].each do |game|
  broker = NativeLiveSessionsBroker.new
  users = %w[Alice Bob Watcher]
  transports = users.to_h { |u| [u,GameRoomTransport.new(ProgramDouble.new(broker.endpoint(u)))] }
  repos = users.to_h { |u| [u,GameRepository.new(ProgramDouble.new(broker.endpoint(u)),transport:transports[u],server_tables:Object.new)] }
  $game_room_test_user='Alice'
  table = transports['Alice'].create_room(name:'Test',game:game.id,owner:'Alice',game_options:JSON.generate(game.default_options))
  users.drop(1).each { |u| $game_room_test_user=u; transports[u].join_room(transports[u].discover_rooms.first,u) }
  $game_room_test_user='Alice'
  session = repos['Alice'].start_session(table:table,game:game.id,players:%w[Alice Bob],options:table['game_options'])
  if game.id=='audio_ball'
    context = GameRoomGames::ActionContext.new(table_owner:'Alice', server_random:true,
      random_source:GameRoomRandom::LocalSecureSource.new)
    before = game.replay(session,[],repos['Alice'])
    status, start = game.action_for(game.automatic_action(before,'Alice',context:context),before,'Alice',context:context)
    assert(status==:ok,'Native initial server draw was not planned')
    repos['Alice'].append_events(session:session,sequence:0,actor:'Alice',events:start.events)
  end
  action = game.id=='audio_ball' ? 'audio_ball_point' : 'pong_point'
  events = repos['Alice'].snapshot_for(session).events
  repos['Alice'].append_events(session:session,sequence:repos['Alice'].next_sequence(session,events),actor:'Alice',events:[{action:action,value:'0:0'}])
  transports['Alice'].transfer_room_owner(table,'Watcher')
  $game_room_test_user='Watcher'
  transports['Watcher'].room_snapshot(table)
  current = repos['Watcher'].session_for_table(table)
  replay = game.replay(current,repos['Watcher'].snapshot_for(current).events,repos['Watcher'])
  assert(replay.state[:scores]==[1,0] && replay.state[:owner]=='Watcher', 'Handover lost previous point or authority')
  ctx = GameRoomGames::ActionContext.new(table_owner:'Watcher',local_data:{action=>'1:1'},now:Time.now.to_i)
  actor = game.automatic_actor(replay,'Watcher',table_owner:'Watcher')
  selection = game.automatic_action(replay,actor,context:ctx)
  status, plan = game.action_for(selection,replay,actor,context:ctx)
  assert(status==:ok,'New spectator master could not validate next point')
  repos['Watcher'].append_events(session:current,sequence:repos['Watcher'].next_sequence(current,replay.accepted_events),actor:actor,controller:true,events:plan.events)
  states=users.map do |u|
    $game_room_test_user=u
    copy=repos[u].session_for_table(table)
    game.replay(copy,repos[u].snapshot_for(copy).events,repos[u]).state
  end
  assert(states.uniq.size==1 && states.first[:scores]==[1,1], 'Old/new master point histories diverged')
end
puts 'Native durable points across observer-master handover: Pong and Audio Ball OK'
