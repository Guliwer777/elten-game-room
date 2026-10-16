require 'tmpdir'
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_readiness_service'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('shared-ready-',ENV.fetch('TMPDIR')) do |directory|
  actor,now='Alice',100
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  candidate={'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
    'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false,'roster'=>%w[alice bob]}
  source=-> {{'candidate'=>candidate,'tournament_id'=>7}}
  journals={}
  make=-> {journal=T::OperationJournal.new(directory:File.join(directory,actor),owner:actor.downcase,backend_identity:'trial:ready');journals[actor]=journal;
    T::ServerReadinessService.new(table:table,journal:journal,user:-> {actor},source:source,clock:-> {now})}
  alice=make.call
  assert_equal(%w[not_ready not_ready],alice.snapshot['participants'].map{|row|row['state']})
  assert_equal(0,table.insert_count,'Entering must not opt in')
  alice.set_available(available:true,intent_id:'alice-ready')
  assert_equal('ready',alice.snapshot['participants'][0]['state'])
  actor='Bob'
  bob=make.call
  assert_equal('ready',bob.snapshot['participants'][0]['state'],'A second client cannot see the first readiness')
  bob.set_available(available:true,intent_id:'bob-ready')
  assert_equal(%w[ready ready],bob.snapshot['participants'].map{|row|row['state']})
  actor='Alice'
  cold=make.call
  assert_equal(%w[ready ready],cold.snapshot['participants'].map{|row|row['state']})
  now=160
  assert_equal(%w[not_ready not_ready],cold.snapshot['participants'].map{|row|row['state']})
  now=161
  cold.set_available(available:true,intent_id:'alice-renew')
  now=162
  cold.set_available(available:false,intent_id:'alice-disable')
  assert_equal('not_ready',cold.snapshot['participants'][0]['state'])
  # Partial newest intent cannot fall back to an older ready event.
  table.on_insert=->(row){raise IOError,'Header write lost' if row['part_index']==0}
  assert_raises(IOError){cold.set_available(available:true,intent_id:'alice-partial')}
  table.on_insert=nil
  assert_equal('unknown',cold.snapshot['participants'][0]['state'])
  before=table.insert_count
  cold.set_available(available:true,intent_id:'alice-partial')
  assert_equal(before+1,table.insert_count,'Only the missing availability payload should be completed')
  assert_equal('ready',cold.snapshot['participants'][0]['state'])
  # Fully stored result with a lost acknowledgement is confirmed read-only.
  table.on_insert=->(row){raise IOError,'Last acknowledgement lost' if row['part_index']==1}
  assert_raises(IOError){cold.set_available(available:false,intent_id:'alice-lost')}
  table.on_insert=nil
  record=journals['Alice'].list.find{|row|row['intent_id']=='shared-ready:alice-lost'}
  before=table.insert_count
  assert_equal('confirmed',make.call.reconcile(record['id'])['status'])
  assert_equal(before,table.insert_count)
  assert_equal('not_ready',cold.snapshot['participants'][0]['state'])
  candidate['roster_generation']='d'*64
  assert_equal('unknown',cold.snapshot['participants'][0]['state'],'Old generation reused as available')
  # New schedule identity isolates old readiness completely.
  candidate['schedule_id']='e'*64
  assert_equal(%w[not_ready not_ready],cold.snapshot['participants'].map{|row|row['state']})
  actor='Bob'
  assert_raises(T::ServerPlanArchive::ContextChanged){cold.snapshot}
  actor='Alice'
  assert_raises(T::ServerPlanArchive::ContextChanged){cold.snapshot}
end
puts 'PASS shared readiness: explicit opt-in, two authenticated simulated clients, cold read, server-time expiry, disable, partial/newest intent, lost acknowledgement readback, generation guards and account latch'
