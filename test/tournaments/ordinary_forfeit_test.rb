require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/session_runner'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_match_service'
T=GameRoomTournaments
Dir.mktmpdir('ordinary-forfeit-',ENV.fetch('TMPDIR')) do |directory|
  actor='Alice'
  game=GameRoomGames::TicTacToe.new
  candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,
    'game_id'=>game.id,'game_options'=>game.default_options,'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},
    'roster'=>%w[alice bob],'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
  table=TournamentServerPlanTableSupport::Table.new(user:-> {actor})
  changes=[]
  make=->(user,path) do
    T::OrdinaryMatchService.new(program:Object.new,registry:GameRoomGames::CATALOG,lobby:nil,games:nil,transport:nil,
      table:table,journal:T::OperationJournal.new(directory:File.join(directory,path),owner:user.downcase,backend_identity:'forfeit-test'),
      source:-> {{'candidate'=>candidate,'tournament_id'=>5}},user:-> {user},
      changed:->(reference){changes<<[user.downcase,reference]})
  end
  organizer=make.call('Alice','alice')
  guest=make.call('Bob','bob')
  args={match_id:'d'*64,leg:1,winner:'bob',expected_schedule_id:'a'*64}
  assert_raises(T::OrdinaryMatchService::Blocked){guest.award_forfeit(**args)}
  assert_equal(0,table.insert_count)
  assert_raises(T::OrdinaryMatchService::Blocked){organizer.award_forfeit(**args.merge(winner:'stranger'))}
  assert_raises(T::OrdinaryMatchService::Blocked){organizer.award_forfeit(**args.merge(expected_schedule_id:'e'*64))}
  assert_equal([],changes,'Rejected forfeit announced a change')
  view=organizer.award_forfeit(**args)
  assert_equal([['alice',candidate['publication_ref']]],changes,'Confirmed forfeit did not wake other views')
  assert_equal(true,view['completed'],'Resolved round-robin remained unfinished')
  assert_equal(2,view['standings'].find{|row|row['unit']=='bob'}['points'])
  assert_equal(0,view['standings'].find{|row|row['unit']=='alice'}['points'])
  assert(view['standings'].all?{|row|row['score_for'].nil?},'Forfeit added small points')
  cold=make.call('Bob','cold-bob')
  assert_equal(view,cold.result_view)
  count=table.insert_count
  organizer.award_forfeit(**args)
  organizer.reconcile(organizer.operations.first['id'])
  assert_equal(count,table.insert_count,'Repeated decision or reconciliation wrote again')
  assert_raises(T::OrdinaryMatchService::Blocked){guest.open_match(match_id:'d'*64,leg:1)}
  assert_raises(T::OrdinaryMatchService::Blocked){organizer.award_forfeit(**args.merge(winner:'alice'))}
  candidate['matches'] << {'match_id'=>'e'*64,'leg'=>2,'number'=>2,'players'=>%w[alice bob]}
  changes.clear
  table.on_insert=->(row){raise IOError,'lost reply' if row['part_index']==row['part_count']}
  assert_raises(IOError){organizer.award_forfeit(**args.merge(match_id:'e'*64,leg:2))}
  assert_equal([],changes,'Unconfirmed write announced success')
  table.on_insert=nil
  pending=organizer.operations.find{|record|JSON.parse(record['values']['document_json'])['match_id']=='e'*64}
  count=table.insert_count
  organizer.reconcile(pending['id'])
  assert_equal([['alice',candidate['publication_ref']]],changes,'Reconciled forfeit did not wake other views')
  assert_equal(count,table.insert_count,'Lost acknowledgement reconciliation retried a write')
  assert_equal(2,cold.result_view['results'].size)
  forged=JSON.parse(organizer.operations.first['values']['document_json'])
  forged['summary']['scores']={'alice'=>0,'bob'=>1}
  anchor=organizer.operations.first['values'].slice(*T::ServerPlanArchive::ANCHOR_FIELDS)
  original=table.rows.dup
  table.rows.reject!{|row|row['operation_key']==anchor['operation_key']}
  T::ServerPlanDocument.encode(forged,anchor:anchor).each{|row|table.insert(row)}
  assert_raises(T::OrdinaryMatchService::Blocked){cold.result_view}
  table.rows.replace(original)
  [organizer,guest,cold].each(&:close)
end
puts 'PASS shared manual forfeit: organizer only, cold second account, 2/0 without small points, immutable result and no table entry or repeated write'
