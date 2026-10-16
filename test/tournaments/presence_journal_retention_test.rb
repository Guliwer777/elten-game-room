require 'tmpdir'
require_relative '../support/native_room_harness'
require_relative '../../lib/tournaments/operation_journal'
include GameRoomTest::Assertions
T=GameRoomTournaments
Dir.mktmpdir('presence-journal-',ENV.fetch('TMPDIR')) do |directory|
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'retention')
  prepare=->(name,kind) do
    values={'operation_key'=>Digest::SHA256.hexdigest(name),'tournament_id'=>1,
      'publication_digest'=>'a'*64,'roster_generation'=>'b'*64,'kind'=>'plan_document',
      'document_json'=>JSON.generate({'kind'=>kind,'nonce'=>name})}
    journal.prepare(kind:'plan_document',intent_id:name,values:values)
  end
  pending=prepare.call('pending','tournament-shared-readiness-v1')
  attempted=prepare.call('unknown','tournament-participant-lease-v1')
  journal.claim(attempted['id'])
  durable=prepare.call('native-create','ordinary-match-create-v1')
  journal.resolve(durable['id'],status:'confirmed',evidence:{'table_id'=>123},expected_revision:1)
  expired=prepare.call('expired-lease','tournament-participant-lease-v1')
  journal.resolve(expired['id'],status:'outside_window',evidence:{'expires_at'=>100},expected_revision:1)
  expired_result=prepare.call('expired-result','ordinary-match-result-v1')
  journal.resolve(expired_result['id'],status:'outside_window',evidence:{'expires_at'=>100},expected_revision:1)
  140.times do |index|
    record=prepare.call("presence-#{index}",index.even? ? 'tournament-shared-readiness-v1' : 'tournament-participant-lease-v1')
    journal.resolve(record['id'],status:'confirmed',evidence:{'row_ids'=>[index+1]},expected_revision:1)
  end
  assert_equal(13,journal.trim_confirmed_presence)
  rows=journal.list
  assert_equal(132,rows.size)
  assert_equal(nil,journal.fetch(expired['id']))
  assert_equal('outside_window',journal.fetch(expired_result['id'])['status'],'Lease expiry retention discarded a result')
  assert_equal('prepared',journal.fetch(pending['id'])['status'])
  assert_equal('attempted',journal.fetch(attempted['id'])['status'])
  assert_equal('confirmed',journal.fetch(durable['id'])['status'])
  assert_equal(nil,journal.find(kind:'plan_document',intent_id:'presence-0'))
  assert(journal.find(kind:'plan_document',intent_id:'presence-139'))
  assert_equal(0,journal.trim_confirmed_presence)
  reopened=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'retention')
  assert_equal(rows,reopened.list)
end
puts 'PASS presence retention: last 128 confirmations; unknown writes, creation and restart recovery preserved'
