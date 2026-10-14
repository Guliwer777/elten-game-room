require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('cancel-match-',ENV.fetch('TMPDIR')) do |directory|
  h=NativeRoomHarness.new(game:GameRoomGames::TicTacToe.new,users:%w[Alice Bob])
  program=ProgramDouble.new(h.broker.endpoint('Alice'))
  lobby=LobbyRepository.new(program,transport:h.transports['Alice'],server_tables:Object.new)
  h.as('Alice'){lobby.close_table(h.table)}
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
  match={'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}
  candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>h.game.id,'game_options'=>h.game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'roster'=>%w[alice bob],'matches'=>[match]}
  make=->(actor) do
    actor_program=ProgramDouble.new(h.broker.endpoint(actor))
    actor_lobby=LobbyRepository.new(actor_program,transport:h.transports[actor],server_tables:Object.new)
    T::OrdinaryMatchService.new(program:actor_program,registry:GameRoomGames::CATALOG,lobby:actor_lobby,games:h.repositories[actor],transport:h.transports[actor],
      table:docs,journal:T::OperationJournal.new(directory:File.join(directory,actor),owner:actor.downcase,backend_identity:'cancel-test'),
      source:-> {{'candidate'=>candidate,'tournament_id'=>5}},user:-> {actor})
  end
  creator=make.call('Alice')
  table=h.as('Alice'){creator.open_match(match_id:match['match_id'],leg:1)}
  h.instance_variable_set(:@table,table)
  guest=make.call('Bob')
  h.as('Bob'){guest.open_match(match_id:match['match_id'],leg:1)}
  started=h.as('Alice'){h.repositories['Alice'].start_session(table:table,game:h.game.id,players:h.users,options:JSON.generate(h.game.default_options),**creator.start_parameters(table,players:h.users))}
  h.instance_variable_set(:@session,started)
  args={match_id:match['match_id'],leg:1,winner:'bob',expected_schedule_id:candidate['schedule_id'],cancel_started:true}
  assert_raises(T::OrdinaryMatchService::Blocked){guest.award_forfeit(**args)}
  assert_equal(1,creator.result_view(include_match_status:true)['cancellable_matches'].size)
  docs.on_insert=->(row){raise IOError,'lost cancellation reply' if row['part_index']==row['part_count']}
  assert_raises(IOError){creator.award_forfeit(**args)}
  docs.on_insert=nil
  pending=creator.operations.find{|record|JSON.parse(record['values']['document_json'])['kind']=='ordinary-match-cancel-forfeit-v1'}
  count=docs.insert_count
  creator.reconcile(pending['id'])
  assert_equal(count,docs.insert_count)
  view=guest.result_view
  assert_equal(2,view['standings'].find{|row|row['unit']=='bob'}['points'])
  assert(view['standings'].all?{|row|row['score_for'].nil?},'Cancellation added small scores')
  assert_equal([],creator.result_view(include_match_status:true)['cancellable_matches'])
  assert_raises(T::OrdinaryMatchService::Blocked){creator.start_parameters(table,players:h.users)}
  12.times do
    replay=h.replay('Alice')
    break if replay.finished?
    actor=replay.current_player
    h.submit(actor,h.game.legal_actions(replay,actor).first)
  end
  replay=h.replay('Alice')
  assert(replay.finished?,'Native game did not finish after sporting cancellation')
  before=docs.insert_count
  binding=creator.instance_variable_get(:@bindings)[table['__id']]
  creator.collect(binding)
  assert_equal(before,docs.insert_count,'Cancelled game exported another tournament result')
  assert_equal(view,guest.result_view,'Later finish replaced cancellation')
  assert_raises(T::OrdinaryMatchService::Blocked){creator.award_forfeit(**args.merge(winner:'alice'))}
  creator.close; guest.close
end
puts 'PASS native sporting cancellation: organizer only, lost acknowledgement recovery, shared 2/0, later game completion excluded and history retained'
