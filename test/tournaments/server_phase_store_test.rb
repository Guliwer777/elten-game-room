require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../support/tournament_server_plan_table'
require_relative '../../lib/tournaments/tables_gateway'
require_relative '../../lib/tournaments/server_phase_store'
include GameRoomTest::Assertions
T=GameRoomTournaments
def candidate(target:nil)
  generation='a'*64
  publication='b'*64
  metadata=T::KnockoutSchedule.direct_metadata(seeds:%w[alice bob],generation:generation,publication_digest:publication,target:target)
  schedule,matches=T::KnockoutSchedule.matches(metadata:metadata,generation:generation)
  {'schedule_id'=>schedule,'publication_digest'=>publication,'roster_generation'=>generation,'game_id'=>'tic_tac_toe',
    'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'format'=>'knockout','players_per_match'=>2,'game_options'=>{},
    'roster'=>%w[alice bob],'matches'=>matches,'knockout'=>metadata,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false}
end
def receipts(phase,winner)
  phase['matches'].map do |match|
    {'match_id'=>match['match_id'],'leg'=>match['leg'],'summary'=>{'participants'=>match['players'].sort,'winners'=>winner ? [winner] : [],'draw'=>winner.nil?,'scores'=>nil,'event_count'=>9}}
  end
end
Dir.mktmpdir('phase-store-',ENV.fetch('TMPDIR')) do |directory|
  root=candidate
  user='Alice'
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {user})
  journal=-> {T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'phase-store-test')}
  results={root['schedule_id']=>receipts(root,nil)}
  source=-> {{'candidate'=>root,'tournament_id'=>9}}
  reader=->(phase,_original){{'results'=>results.fetch(phase['schedule_id'],[])}}
  make=-> {T::ServerPhaseStore.new(table:docs,journal:journal.call,user:-> {user},source:source,results:reader)}
  docs.on_insert=->(row){raise IOError,'Phase saved but reply lost' if row['part_index']==row['part_count']}
  assert_raises(IOError){make.call.advance(expected_schedule_id:root['schedule_id'])}
  pending=journal.call.list.first
  assert_equal('attempted',pending['status'])
  before=docs.insert_count
  docs.on_insert=nil
  assert_equal('confirmed',make.call.reconcile(pending['id'])['status'])
  assert_equal(before,docs.insert_count,'Uncertain phase was resent')
  replay=make.call.current['candidate']
  assert_equal(1,replay['knockout']['replay']['attempt'])
  assert_equal(false,replay['dispatch_allowed'])
  assert_equal(false,replay['start_allowed'])
  results[replay['schedule_id']]=receipts(replay,'alice')
  assert_equal(:tournament_completed,assert_raises(T::Publication::Invalid){make.call.advance(expected_schedule_id:replay['schedule_id'])}.code)
  results[root['schedule_id']]=receipts(root,'bob')
  assert_raises(T::Publication::Invalid){make.call.current}
  results[root['schedule_id']]=receipts(root,nil)
  retained=JSON.parse(JSON.generate(docs.rows))
  docs.rows.delete_if{|row|row['part_index']==row['part_count']}
  assert_equal(:incomplete_plan_document,assert_raises(T::Publication::Invalid){make.call.current}.code)
  assert_equal(before,docs.insert_count,'Partial read caused new publication')
  docs.rows.replace(retained)
  user='Bob'
  assert_raises(T::ServerPlanArchive::ContextChanged){make.call.current}
end
first=candidate(target:2)
second=T::ServerPhasePlan.build(candidate:first,results:receipts(first,'alice'))['candidate']
assert_equal(2,second['knockout']['series']['attempt'])
assert_equal(2,second['knockout']['series']['target'])
assert_equal(:tournament_completed,assert_raises(T::Publication::Invalid){T::ServerPhasePlan.build(candidate:second,results:receipts(second,'alice'))}.code)
assert_equal(:phase_results_incomplete,assert_raises(T::Publication::Invalid){T::ServerPhasePlan.build(candidate:first,results:[])}.code)
puts 'PASS shared phases: draw adds only the required replay, win series progression, completed final, cold lost-reply recovery without resend, changed results, partial documents and account guard'
