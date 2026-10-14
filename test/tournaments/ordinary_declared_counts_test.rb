require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('ordinary-counts-',ENV.fetch('TMPDIR')) do |directory|
  users=%w[Alice Bob Carol]
  game=GameRoomGames::ThreeFiveEight.new
  h=NativeRoomHarness.new(game:game,users:users)
  programs=users.to_h{|user|[user,ProgramDouble.new(h.broker.endpoint(user))]}
  lobbies=users.to_h{|user|[user,LobbyRepository.new(programs[user],transport:h.transports[user],server_tables:Object.new)]}
  h.as('Alice'){lobbies['Alice'].close_table(h.table)}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  match={'match_id'=>'d'*64,'leg'=>1,'players'=>%w[alice bob]}
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>game.id,
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'format'=>'round_robin','players_per_match'=>3,
    'game_options'=>game.default_options,'roster'=>%w[alice bob carol],'matches'=>[match]}
  source=-> {{'candidate'=>candidate,'tournament_id'=>5}}
  services=users.to_h do |user|
    journal=T::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'native-counts')
    [user,T::OrdinaryMatchService.new(program:programs[user],registry:GameRoomGames::CATALOG,lobby:lobbies[user],games:h.repositories[user],
      transport:h.transports[user],table:docs,journal:journal,source:source,user:-> {user})]
  end
  begin
    assert_raises(T::OrdinaryMatchService::Blocked){services['Alice'].open_match(match_id:'d'*64,leg:1)}
    assert_equal(0,docs.insert_count,'Illegal 3-5-8 count wrote a binding')
    assert_equal(nil,h.as('Alice'){lobbies['Alice'].current_table_for('Alice')},'Illegal count created a native table')
    match['players']=%w[alice bob carol]
    table=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
    h.instance_variable_set(:@table,table)
    users.drop(1).each{|user|h.as(user){services[user].open_match(match_id:'d'*64,leg:1)}}
    parameters=services['Alice'].start_parameters(table,players:users.reverse)
    assert_equal(users,parameters[:players])
    h.as('Alice') do
      session=h.repositories['Alice'].start_session(table:table,game:game.id,options:JSON.generate(game.default_options),**parameters)
      h.instance_variable_set(:@session,session)
    end
    assert_equal(users,h.replay('Alice').players)
    assert_equal(parameters[:requested_session_id],h.session['__id'])
  ensure
    services.each_value(&:close)
  end
end
puts 'PASS declared counts through real native entry: 3-5-8 rejects two players before writes/table creation, three authorized clients join one bound table and start at the planned seats/session'
