require 'tmpdir'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments

def scenario
  Dir.mktmpdir('ordinary-invitation-',ENV.fetch('TMPDIR')) do |directory|
    h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
    docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
    candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
      'game_id'=>h.game.id,'game_options'=>h.game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
      'roster'=>%w[alice bob],'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
    lobbies={};services={}
    h.users.each do |user|
      program=ProgramDouble.new(h.broker.endpoint(user))
      lobbies[user]=LobbyRepository.new(program,transport:h.transports[user],server_tables:Object.new)
      services[user]=T::OrdinaryMatchService.new(program:program,registry:GameRoomGames::CATALOG,lobby:lobbies[user],
        games:h.repositories[user],transport:h.transports[user],table:docs.for_user(user),
        journal:T::OperationJournal.new(directory:File.join(directory,user),owner:user.downcase,backend_identity:'invitation-test'),
        source:-> {{'candidate'=>candidate,'tournament_id'=>1}},user:-> {user})
    end
    h.as('Alice'){lobbies['Alice'].close_table(h.table)}
    yield h,services,lobbies,docs,candidate
  ensure
    services&.each_value(&:close)
  end
end

scenario do |h,services,lobbies,docs,candidate|
  # Any planned player may create; native ownership does not reorder seats.
  table=h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  assert_equal('Bob',table['owner'])
  assert_equal(candidate.slice('publication_ref','schedule_id').merge('match_id'=>'d'*64,'leg'=>1),table['tournament_match'])
  writes=docs.insert_count
  h.as('Alice') do
    assert(services['Alice'].attach_table(table))
    lobbies['Alice'].join_table(table,'Alice')
  end
  assert_equal(writes,docs.insert_count,'Accepting an ordinary invitation writes consent/readiness')
  docs.on_select=-> {raise 'Presentation made an unnecessary server read'}
  assert(services['Alice'].attached_table?(table))
  assert(!services['Alice'].attached_table?(table.merge('__live_session_id'=>'another-native-room')))
  assert(!services['Alice'].attached_table?(table.merge('tournament_match'=>table['tournament_match'].merge('leg'=>2))))
  docs.on_select=nil
  params=h.as('Bob'){services['Bob'].start_parameters(table,players:%w[Bob Alice])}
  assert_equal(%w[Alice Bob],params[:players])
  h.instance_variable_set(:@table,table)
  h.as('Bob') do
    started=h.repositories['Bob'].start_session(table:table,game:h.game.id,options:JSON.generate(h.game.default_options),**params)
    h.instance_variable_set(:@session,started)
  end
  assert_equal([],services['Alice'].result_view['results'],'Starting alone awarded a result')
end

scenario do |h,services,lobbies,docs,_|
  first=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
  writes=docs.insert_count
  # Decline/expiry only belong to the ordinary invitation, not match scoring.
  assert_equal([],services['Bob'].result_view['results'])
  assert_equal(writes,docs.insert_count)
  h.as('Alice'){lobbies['Alice'].close_table(first)}
  second=h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  assert(first['__live_session_id']!=second['__live_session_id'],'Closed empty table was not replaced')
  assert_equal('Bob',second['owner'])
  assert_raises(T::OrdinaryMatchService::Blocked){services['Alice'].attach_table(first)}
  assert(services['Alice'].attach_table(second))
  reopened=h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  assert_equal(second['__live_session_id'],reopened['__live_session_id'])
  assert_equal(1,h.broker.cores.values.count{|core|!core.closed},'Retry created duplicate live tables')
end

scenario do |h,services,lobbies,docs,_|
  # A second Play interleaved with the first creator document cannot create.
  rejected=false
  docs.on_insert=->(row) do
    docs.on_insert=nil
    error=assert_raises(T::Publication::Invalid){h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}}
    assert_equal(:incomplete_plan_document,error.code)
    rejected=true
  end
  table=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
  assert(rejected)
  h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}
  assert_equal(1,h.broker.cores.values.count{|core|!core.closed},'Concurrent entry created duplicate tables')
  services['Alice'].start_parameters(table,players:%w[Alice Bob])
  h.as('Alice'){lobbies['Alice'].close_table(table)}
  count=h.broker.cores.size
  error=assert_raises(T::OrdinaryMatchService::Blocked){h.as('Bob'){services['Bob'].open_match(match_id:'d'*64,leg:1)}}
  assert_equal(:closed_match_needs_recovery,error.code)
  assert_equal(count,h.broker.cores.size,'Uncertain native start created another game')
end

scenario do |h,services,lobbies,_,_|
  table=h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}
  h.as('Bob'){services['Bob'].attach_table(table);lobbies['Bob'].join_table(table,'Bob')}
  # Transient discovery failure is not evidence that a table was closed.
  h.transports['Alice'].define_singleton_method(:current_room){|*|nil}
  h.transports['Alice'].define_singleton_method(:discover_rooms){|**|raise IOError,'discovery offline'}
  count=h.broker.cores.size
  assert_raises(IOError){h.as('Alice'){services['Alice'].open_match(match_id:'d'*64,leg:1)}}
  assert_equal(count,h.broker.cores.size)
end
puts 'PASS ordinary invitations: either creator, fixed seats, read-only acceptance, empty-table retry, old invitation rejection, concurrent entry, uncertain start and offline discovery'
