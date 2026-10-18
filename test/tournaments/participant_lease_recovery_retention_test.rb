require_relative '../support/temporary_directory'
require 'tmpdir'
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_participant_lease'
include GameRoomTest::Assertions
T=GameRoomTournaments
subject={'publication_ref'=>{'author'=>'owner','publication_key'=>'test'},'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1}
GameRoomTest::TemporaryDirectory.create('lease-recovery-') do |directory|
  actor,now='alice',100
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  journal=T::OperationJournal.new(directory:directory,owner:actor,backend_identity:'audit-lease')
  build=-> {T::ServerParticipantLease.new(table:table,journal:journal,user:-> {actor},clock:-> {now})}
  service=build.call
  table.on_insert=->(row){raise IOError,'Lost header reply' if row['part_index']==0}
  assert_raises(IOError){service.acquire(subject:subject,token:'c'*64)}
  table.on_insert=nil
  pending=journal.list.last
  assert_raises(T::Publication::Invalid){build.call.state}
  now=230
  assert_equal(nil,build.call.state,'Expired partial lease blocked the account')
  before=table.insert_count
  assert_equal('outside_window',build.call.reconcile(pending['id'])['status'])
  assert_equal(before,table.insert_count,'Recovery completed an expired reservation')
  assert_equal('d'*64,build.call.acquire(subject:subject,token:'d'*64)['token'])
  # Even an external late completion must not take the new lease away.
  old=JSON.parse(pending['values']['document_json'])
  anchor=pending['values'].slice(*T::ServerPlanArchive::ANCHOR_FIELDS)
  T::ServerPlanDocument.encode(old,anchor:anchor).drop(1).each{|row|table.insert(row)}
  assert_equal('d'*64,build.call.state['token'])
  now+=10
  assert_equal('d'*64,build.call.renew(token:'d'*64)['token'])
  release=build.call.release(token:'d'*64)
  assert_equal(nil,release)
  # Replayed complete acquire, including its checkpoint, is not a new claim.
  acquired=journal.list.find{|row|JSON.parse(row['values']['document_json'])['token']=='d'*64}
  copy=JSON.parse(acquired['values']['document_json'])
  T::ServerPlanDocument.encode(copy,anchor:acquired['values'].slice(*T::ServerPlanArchive::ANCHOR_FIELDS)).each{|row|table.insert(row)}
  assert_equal(nil,build.call.state)
  assert_equal('e'*64,build.call.acquire(subject:subject,token:'e'*64)['token'])
  build.call.release(token:'e'*64)
  now+=121
  assert_equal(nil,build.call.state)
  assert_raises(T::ServerParticipantLease::Busy){build.call.acquire(subject:subject,token:'d'*64)}
  assert_raises(T::ServerParticipantLease::Busy){build.call.acquire(subject:subject,token:'e'*64)}
  assert_equal('f'*64,build.call.acquire(subject:subject,token:'f'*64)['token'])
  actor='bob'
  assert_raises(T::ServerPlanArchive::ContextChanged){service.state}
end

GameRoomTest::TemporaryDirectory.create('lease-delayed-release-') do |directory|
  now=100
  table=ReadinessPlanTableSupport::Table.new(user:-> {'alice'},clock:-> {now})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'audit-delayed-release')
  build=-> {T::ServerParticipantLease.new(table:table,journal:journal,user:-> {'alice'},clock:-> {now})}
  service=build.call
  token='d'*64
  service.acquire(subject:subject,token:token)
  # Another client prepared a release before the first client renewed the
  # same reservation. Delivery was delayed, not the upload of its parts.
  release={'kind'=>T::ServerParticipantLease::KIND,'account'=>'alice','action'=>'release','subject'=>subject,
    'token'=>token,'expires_at'=>now+120,'nonce'=>SecureRandom.uuid,'checkpoint'=>service.send(:history,'alice')}
  now=180
  build.call.renew(token:token)
  now=250
  build.call.renew(token:token)
  assert_equal(token,build.call.state['token'])
  T::ServerPlanDocument.encode(release,anchor:service.send(:event_anchor,release,'alice')).each{|row|table.insert(row)}
  assert_equal(nil,build.call.state,'A delayed release was ignored after its intent expired')
  assert_raises(T::ServerParticipantLease::Busy){build.call.acquire(subject:subject,token:token)}
end

GameRoomTest::TemporaryDirectory.create('lease-history-') do |directory|
  now=100
  table=ReadinessPlanTableSupport::Table.new(user:-> {'alice'},clock:-> {now})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'audit-history')
  build=-> {T::ServerParticipantLease.new(table:table,journal:journal,user:-> {'alice'},clock:-> {now})}
  service=build.call
  anchor=service.send(:anchor,'alice')
  # Existing append-only format: many old matches, no checkpoints yet.
  2500.times do |index|
    now=100+index*130
    event={'kind'=>T::ServerParticipantLease::KIND,'account'=>'alice','action'=>'acquire','subject'=>subject,
      'token'=>Digest::SHA256.hexdigest(index.to_s),'expires_at'=>now+120,'nonce'=>SecureRandom.uuid}
    T::ServerPlanDocument.encode(event,anchor:anchor).each{|row|table.insert(row)}
  end
  token=Digest::SHA256.hexdigest('2499')
  assert_equal(token,build.call.state['token'])
  now+=60
  assert_equal(token,build.call.renew(token:token)['token'])
  # A fresh reader must use the persisted checkpoint, not an in-memory cache.
  reads=[]
  table.singleton_class.prepend(Module.new do
    define_method(:select) do |**args|
      super(**args).tap{|rows|reads << rows.size}
    end
  end)
  150.times do
    now+=60
    assert_equal(token,build.call.renew(token:token)['token'])
  end
  assert(reads.max<40,'A checkpoint reader downloaded historical pages')
  reads.clear
  assert_equal(token,build.call.state['token'])
  assert(reads.sum<50,"Cold read grew with all renewals: #{reads.inspect}")
  cold_reads=reads.dup
  assert(journal.list.size<=129,'Local confirmed leases grew without retention')
  build.call.release(token:token)
  assert_equal(nil,build.call.state)
  now+=121
  assert_equal('f'*64,build.call.acquire(subject:subject,token:'f'*64)['token'])
  puts "PASS bounded lease read after 2500 historical claims and 150 cold renewals: #{cold_reads.size} selects, #{cold_reads.sum} returned rows"
end

GameRoomTest::TemporaryDirectory.create('lease-race-') do |directory|
  now=100
  table=ReadinessPlanTableSupport::Table.new(user:-> {'alice'},clock:-> {now})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'audit-race')
  build=-> {T::ServerParticipantLease.new(table:table,journal:journal,user:-> {'alice'},clock:-> {now})}
  service=build.call
  anchor=service.send(:anchor,'alice')
  prefix=service.send(:history,'alice')
  # Two writers observed the same empty prefix. The second checkpoint must
  # still replay the first claim, not blindly accept its own current value.
  %w[c d].each do |letter|
    event={'kind'=>T::ServerParticipantLease::KIND,'account'=>'alice','action'=>'acquire','subject'=>subject,
      'token'=>letter*64,'expires_at'=>now+120,'nonce'=>SecureRandom.uuid,'checkpoint'=>prefix}
    T::ServerPlanDocument.encode(event,anchor:anchor).each{|row|table.insert(row)}
  end
  assert_equal('c'*64,build.call.state['token'],'Concurrent checkpoint replaced the earlier claim')
  assert_raises(T::ServerParticipantLease::Busy){build.call.acquire(subject:subject,token:'d'*64)}
  build.call.release(token:'c'*64)
  assert_equal(nil,build.call.state,'Previously losing claim became active after release')
  assert_equal(nil,build.call.renew(token:'d'*64))
  now+=121
  assert_raises(T::ServerParticipantLease::Busy){build.call.acquire(subject:subject,token:'c'*64)}
end
puts 'PASS lease expiry, incomplete upload recovery, late completion, duplicate checkpoint, competing claims and cold bounded history'
