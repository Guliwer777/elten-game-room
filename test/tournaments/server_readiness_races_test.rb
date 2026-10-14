require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_readiness_service'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('ready-races-',ENV.fetch('TMPDIR')) do |directory|
  actor,now='Alice',100
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  candidate={'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
    'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false,'roster'=>%w[alice bob]}
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'ready-races')
  service=T::ServerReadinessService.new(table:table,journal:journal,user:-> {actor},
    source:-> {{'candidate'=>candidate,'tournament_id'=>7}},clock:-> {now})
  table.on_insert=->(row){raise IOError,'Delayed first payload' if row['part_index']==0}
  assert_raises(IOError){service.set_available(available:true,intent_id:'older-ready')}
  table.on_insert=nil
  older=journal.list.find{|row|row['intent_id']=='shared-ready:older-ready'}
  old_document=T::StrictJson.parse(older['values']['document_json'],max_nesting:12)
  header=table.rows.first
  anchor=header.slice('operation_key','tournament_id','publication_digest','roster_generation')
  now=101
  service.set_available(available:false,intent_id:'newer-disable')
  # A payload completing an older intent arrives after the newer withdrawal.
  T::ServerPlanDocument.encode(old_document,anchor:anchor).drop(1).each{|row|table.insert(row)}
  assert_equal('not_ready',service.snapshot['participants'][0]['state'],'Late old completion overrode withdrawal')
  assert_equal('confirmed',service.reconcile(older['id'])['status'])
  assert_equal('not_ready',service.snapshot['participants'][0]['state'])
  now=nil
  before=table.insert_count
  assert_raises(T::Publication::Invalid){service.set_available(available:true,intent_id:'missing-clock')}
  assert_equal(before,table.insert_count,'Unavailable clock allowed a write')
  now=102
  service.set_available(available:true,intent_id:'current-ready')
  latest=table.rows.select{|row|row['part_index']==0}.max_by{|row|row['__id']}
  latest['__insertion_time']=103
  assert_equal('unknown',service.snapshot['participants'][0]['state'],'Future server timestamp trusted')
  latest['__insertion_time']=102
  parts=table.rows.select{|row|row['document_digest']==latest['document_digest']}
  parts.last['__insertion_user']='Bob'
  assert_equal('unknown',service.snapshot['participants'][0]['state'],'Foreign payload author trusted')
  parts.last['__insertion_user']='Alice'
  assert_equal('ready',service.snapshot['participants'][0]['state'])
  # Old history must not exhaust the active-read budget; authenticated newer
  # headers still prevent resurrection when server timestamps move backwards.
  retained=table.rows.map{|row|JSON.parse(JSON.generate(row))}
  table.rows.replace(retained.map{|row|row.merge('__id'=>row['__id']+1100)})
  1100.times do |index|
    old=retained.first.merge('__id'=>index+1,'__insertion_time'=>0)
    table.rows<<old
  end
  assert_equal('ready',service.snapshot['participants'][0]['state'])
  table.rows.replace(retained)
  now=1
  service.set_available(available:false,intent_id:'server-clock-backwards')
  now=102
  assert_equal('unknown',service.snapshot['participants'][0]['state'],'Time filter resurrected an older Ready after newer expired Disable')
  table.on_select=-> {candidate['roster_generation']='d'*64}
  assert_raises(T::ServerPlanArchive::ContextChanged){service.snapshot}
  table.on_select=nil
  assert_equal('unknown',service.snapshot['participants'][0]['state'])
end
puts 'PASS readiness races: delayed old payload cannot undo withdrawal, cold reconciliation preserves ordering, missing clock prevents writes, future/foreign metadata stays unknown, changed roster invalidates read'
