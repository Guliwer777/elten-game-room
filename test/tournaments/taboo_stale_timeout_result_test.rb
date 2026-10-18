require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../support/elten_array_shuffle'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_results'

game = GameRoomGames::Taboo.new
users = %w[Alice Bob Carol Dave]
options = game.with_team_assignment(game.default_options.merge('turns_each'=>1,'turn_seconds'=>30),
  players:users,seats:[0,1,0,1])
h, runners = PrivateCardGamesTest.create(game,users:users,options:options)
begin
  play = lambda do |user, action, now = nil|
    snapshot = h.repositories.fetch(user).snapshot_for(h.session)
    h.instance_variable_set(:@session,snapshot.session)
    replay = game.replay(snapshot.session,snapshot.events,h.repositories.fetch(user))
    context = GameRoomGames::ActionContext.new(table_owner:h.core.owner,now:now || replay.state[:time] + 1)
    h.submit(user,{'action'=>action,'token'=>game.token(replay.state)},context:context)
  end
  tick = -> {5.times {PrivateCardGamesTest.tick(h,runners)}}
  race = nil
  4.times do |turn|
    giver = h.replay('Alice').current_player
    play.call(giver,'start')
    play.call('Alice','begin',h.replay('Alice').state[:deadline])
    if turn.zero?
      tick.call
      play.call(giver,'correct')
      old = h.replay('Alice')
      context = GameRoomGames::ActionContext.new(table_owner:'Alice',now:old.state[:deadline])
      status, timeout = game.action_for({'action'=>'timeout','token'=>game.token(old.state)},old,'Alice',context:context)
      assert_equal(:ok,status)
      mine = h.replay(giver)
      choice = game.automatic_action(mine,giver,context:context)
      assert_equal('taboo_draw',choice.fetch('action'))
      h.submit(giver,choice,context:context)
      h.write('Alice',timeout.events)
      race = timeout.events.size
      assert_equal(old.state[:revision] + 1,h.replay('Alice').state[:revision])
      assert_equal(:describing,h.replay('Alice').state[:phase])
    else
      tick.call
    end
    play.call('Alice','timeout',h.replay('Alice').state[:deadline])
    tick.call
    assert_equal(:review,h.replay('Alice').state[:phase])
    play.call('Alice','approve')
    tick.call
  end
  replay = h.replay('Alice')
  assert(replay.finished?,'Private Taboo fixture did not finish')
  assert_equal([0,1],replay.state[:scores].sort)
  assert_equal(race,h.events('Alice').size-replay.accepted_events.size)
  options = game.options_from_json(h.session.fetch('options'))
  binding = {'match_id'=>'taboo-stale','leg'=>1,'table'=>h.table.slice('__id','__live_session_id'),
    'session_id'=>h.session['__id'],'game_id'=>'taboo','options'=>options,
    'players'=>h.users.each_with_index.map { |name,index| {'username'=>name,'account'=>name.downcase,'team'=>"unit-#{options.fetch('team_seats').fetch(index)}"} }}
  results = h.users.map do |user|
    h.as(user) {GameRoomTournaments::OrdinaryMatchResults.read(repository:h.repositories.fetch(user),
      registry:GameRoomGames::CATALOG,transport:h.transports.fetch(user),table:h.table,binding:binding)}
  end
  assert_equal(1,results.uniq.size)
  assert_equal(h.events('Alice').size,results.first['summary']['event_count'])
  assert_equal([0,1],results.first['summary']['scores'].values.sort)
  assert(h.users.all? { |user| !h.replay(user).state[:private_error] },'Private audit failed')
  puts 'PASS actual local private Taboo protocol: concurrent draw versus lawful timeout, four full turns, reveal audit, four identities and identical complete-history result'
ensure
  runners.each_value(&:close)
end
