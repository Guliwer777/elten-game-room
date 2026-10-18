require_relative '../support/assertions'
require_relative '../support/temporary_directory'
require_relative '../support/tournament_server_plan_table'
require_relative '../../lib/tournaments/server_plan_archive'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomTest::TemporaryDirectory.create('document-digest-attempt-') do |directory|
  table=TournamentServerPlanTableSupport::Table.new(user:-> {'alice'})
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'digest-attempt')
  anchor={'operation_key'=>'a'*64,'tournament_id'=>5,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64}
  a={'state'=>'first','details'=>'A'*5000}
  b={'state'=>'second','details'=>'B'*5000}
  digest=->(doc) {Digest::SHA256.hexdigest(JSON.generate(T::ServerPlanDocument.copy_document(doc)))}
  permitted=true
  archive=->(doc,**overrides) {
    T::ServerPlanArchive.new(table:table,journal:journal,user:-> {'alice'},
      document_digest:digest.call(doc),verify:->(value,key) {permitted && value==doc && key==anchor},**overrides)
  }
  table.on_insert=->(row) {raise IOError,'partial attempt' if row['part_index']==1}
  assert_raises(IOError) {archive.call(a).publish(intent_id:'attempt-a',document:a,anchor:anchor)}
  saved=table.rows.map(&:dup)
  table.on_insert=nil
  record=archive.call(b).publish(intent_id:'attempt-b',document:b,anchor:anchor)
  assert_equal('confirmed',record['status'])
  assert_equal(saved,table.rows.first(saved.size))
  assert_equal(b,T::ServerPlanDocument.decode(table.rows.select { |row| row['document_digest']==digest.call(b) },anchor:anchor,author:'alice'))
  writes=table.insert_count
  permitted=false
  old=journal.find(kind:'plan_document',intent_id:'attempt-a')
  assert_raises(T::Publication::Invalid) {archive.call(a).resume(old['id'])}
  assert_equal(writes,table.insert_count,'Revoked immutable attempt was resumed')
  permitted=true
  # Default callers must not start accepting distinct documents under one key.
  strict=T::ServerPlanArchive.new(table:table,journal:journal,user:-> {'alice'},verify:->(*) {true})
  assert_raises(T::Publication::Invalid) {strict.resume(old['id'])}
  assert_equal(writes,table.insert_count)
  # An opt-in digest is a guard, not an unrestricted table-filter hint.
  bad=T::ServerPlanArchive.new(table:table,journal:journal,user:-> {'alice'},document_digest:digest.call(b),verify:->(*) {true})
  assert_raises(T::Publication::Invalid) {bad.publish(intent_id:'mismatched',document:a,anchor:anchor)}
  assert_equal(nil,journal.find(kind:'plan_document',intent_id:'mismatched'))
  assert_equal(writes,table.insert_count)
end
puts 'PASS opt-in digest archive: isolated immutable parts/intents, authorization, strict legacy default and mismatched digest no-I/O denial'
