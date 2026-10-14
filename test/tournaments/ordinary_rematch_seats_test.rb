require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('return-colours-',ENV.fetch('TMPDIR')) do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::Chess.new,users:%w[Alice Bob])
  programs=h.users.to_h{|name|[name,ProgramDouble.new(h.broker.endpoint(name))]}
  lobbies=h.users.to_h{|name|[name,LobbyRepository.new(programs[name],transport:h.transports[name],server_tables:Object.new)]}
  h.as('Alice'){lobbies['Alice'].close_table(h.table)}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {Session.name})
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>'chess',
    'publication_ref'=>{'author'=>'alice','publication_key'=>'return-colours'},'game_options'=>h.game.default_options,'roster'=>%w[alice bob],
    'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]},
      {'match_id'=>'e'*64,'leg'=>2,'number'=>2,'players'=>%w[alice bob]}]}
  services=h.users.to_h do |name|
    journal=T::OperationJournal.new(directory:File.join(directory,name),owner:name.downcase,backend_identity:'return-colours')
    [name,T::OrdinaryMatchService.new(program:programs[name],registry:GameRoomGames::CATALOG,lobby:lobbies[name],games:h.repositories[name],
      transport:h.transports[name],table:docs,journal:journal,source:->{{'candidate'=>candidate,'tournament_id'=>5}},user:-> {name})]
  end
  before=JSON.generate(candidate)
  begin
    candidate['matches'].each do |match|
      order=T::MatchOrder.players(candidate['matches'],match).map(&:capitalize)
      host,guest=order
      assert_raises(T::OrdinaryMatchService::Blocked){h.as(guest){services[guest].open_match(match_id:match['match_id'],leg:match['leg'])}}
      room=h.as(host){services[host].open_match(match_id:match['match_id'],leg:match['leg'])}
      h.as(guest){services[guest].open_match(match_id:match['match_id'],leg:match['leg'])}
      params=h.as(host){services[host].start_parameters(room,players:%w[Alice Bob],options:h.game.default_options)}
      assert_equal(order,params.fetch(:players))
      started=h.as(host){h.repositories[host].start_session(table:room,game:'chess',players:%w[Alice Bob],options:JSON.generate(h.game.default_options),**params)}
      replay=h.game.replay(started,[],h.repositories[host])
      assert_equal(order,replay.players)
      assert_equal('w',h.game.send(:colour_for,replay.state,host))
      assert_equal('b',h.game.send(:colour_for,replay.state,guest))
      h.as(guest){lobbies[guest].leave_table(room,guest)}
      h.as(host){lobbies[host].close_table(room)}
    end
    assert_equal(before,JSON.generate(candidate),'Return order must not rewrite published identities')
  ensure
    services.each_value(&:close)
  end
end
puts 'PASS ordinary chess return: reversed table creator, enforced session order, white/black swap and immutable plan'