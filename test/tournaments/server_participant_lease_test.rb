require 'tmpdir'
require_relative '../support/native_room_harness'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_participant_lease'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('participant-lease-',ENV.fetch('TMPDIR')) do |directory|
  actor,now='Alice',100
  table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'leases')
  build=-> {T::ServerParticipantLease.new(table:table,journal:journal,user:-> {actor},clock:-> {now})}
  service=build.call
  subject={'publication_ref'=>{'author'=>'owner','publication_key'=>'test'},'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1}
  token='c'*64
  assert_equal(nil,service.state)
  assert_equal(token,service.acquire(subject:subject,token:token)['token'])
  before=table.insert_count
  assert_equal(token,build.call.acquire(subject:subject,token:token)['token'])
  assert_equal(before,table.insert_count,'Repeated consent duplicated a lease')
  assert_raises(T::ServerParticipantLease::Busy){service.acquire(subject:subject.merge('match_id'=>'d'*64),token:'e'*64)}
  assert_equal(before,table.insert_count,'Busy account wrote another claim')
  now=180
  assert_equal(300,service.renew(token:token)['expires_at'])
  # A replayed old document does not renew or replace the new lease.
  old=table.rows.first(table.rows.first['part_count']+1).map{|row|row.slice(*T::ServerPlanDocument::FIELDS)}
  old.each{|row|table.insert(row)}
  assert_equal(300,service.state['expires_at'])
  now=200
  service.release(token:token)
  assert_equal(nil,service.state)
  old.each{|row|table.insert(row)}
  assert_equal(nil,service.state,'Delayed duplicate revived released consent')
  assert_equal('e'*64,service.acquire(subject:subject,token:'e'*64)['token'])
  now=321
  assert_equal(nil,service.state,'Dead client reserved account forever')
  # The other account cannot forge a lease for Alice through payload fields.
  actor='Bob'
  old.each{|row|table.insert(row)}
  actor='Alice'
  assert_equal(nil,service.state)
  table.on_insert=->(row){raise IOError,'Lost part' if row['part_index']==0}
  assert_raises(IOError){service.acquire(subject:subject,token:'f'*64)}
  table.on_insert=nil
  assert_raises(T::Publication::Invalid){service.state}
  pending=journal.list.find{|row|row['status']=='attempted'}
  assert_equal('confirmed',build.call.reconcile(pending['id'])['status'])
  assert_equal('f'*64,service.state['token'])
  actor='Bob'
  assert_raises(T::ServerPlanArchive::ContextChanged){service.state}
end
Dir.mktmpdir('participant-lease-clock-',ENV.fetch('TMPDIR')) do |directory|
  now=100
  stamp=101
  table=ReadinessPlanTableSupport::Table.new(user:-> {'Alice'},clock:-> {stamp})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'clock')
  service=T::ServerParticipantLease.new(table:table,journal:journal,user:-> {'Alice'},clock:-> {now})
  subject={'publication_ref'=>{'author'=>'owner','publication_key'=>'test'},'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1}
  assert_equal(220,service.acquire(subject:subject,token:'c'*64)['expires_at'],'A server stamp one second ahead rejected consent')
  now=180
  stamp=178
  assert_equal(298,service.renew(token:'c'*64)['expires_at'],'Client skew extended the server lease')
  now=298
  assert_equal(nil,service.state)
  stamp=400
  assert_raises(T::Publication::Invalid){service.acquire(subject:subject,token:'d'*64)}
end
puts 'PASS participant leases: one active match, cold readback, renewal, expiry, duplicate/foreign rejection, withdrawal and partial-write recovery'
