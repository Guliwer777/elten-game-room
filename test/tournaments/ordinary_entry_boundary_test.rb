require 'tmpdir'
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('ordinary-entry-',ENV.fetch('TMPDIR')) do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
  program=ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby=LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
  h.as('Alice'){lobby.close_table(h.table)}
  candidate={'schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'game_id'=>h.game.id,
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'game_options'=>h.game.default_options,
    'roster'=>%w[alice bob],'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'entry-test')
  allowed=true
  native_lookup=lobby.method(:current_table_for)
  lobby.define_singleton_method(:current_table_for) do |*args|
    allowed=false
    native_lookup.call(*args)
  end
  guard=->(*) {raise T::OrdinaryMatchService::Blocked,:source_changed unless allowed; true}
  service=T::OrdinaryMatchService.new(program:program,registry:GameRoomGames::CATALOG,lobby:lobby,
    games:h.repositories['Alice'],transport:h.transports['Alice'],table:docs,journal:journal,
    source:-> {{'candidate'=>candidate,'tournament_id'=>1}},user:-> {'Alice'},entry_guard:guard)
  assert_raises(T::OrdinaryMatchService::Blocked){h.as('Alice'){service.open_match(match_id:'d'*64,leg:1)}}
  assert_equal(nil,h.as('Alice'){native_lookup.call('Alice')},'Revoked authorization still created a table')
  assert_equal([],journal.list,'A denied boundary created an operation')
  lobby.define_singleton_method(:current_table_for,native_lookup)
  allowed=true
  table=h.as('Alice'){service.open_match(match_id:'d'*64,leg:1)}
  assert(table,'The denied, still-unattempted creation could not be retried')
  assert(journal.list.all?{|record|record['status']=='confirmed'})
  allowed=false
  assert_raises(T::OrdinaryMatchService::Blocked){h.as('Alice'){service.open_match(match_id:'d'*64,leg:1)}}
ensure
  service&.close
end
puts 'PASS entry boundary: authorization after room lookup, denied creation unclaimed, retry without duplicate table, bound reentry still authorized'
