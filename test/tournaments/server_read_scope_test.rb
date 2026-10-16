require 'tmpdir'
require_relative '../support/assertions'
require_relative '../support/tournament_server_plan_table'
require_relative '../../lib/tournaments/server_read_scope'
require_relative '../../lib/tournaments/server_plan_archive'
require_relative '../../lib/tournaments/server_document_rows'
include GameRoomTest::Assertions
T=GameRoomTournaments
raw=TournamentServerPlanTableSupport::Table.new(user:-> {'alice'})
table=T::ServerReadScope::Table.new(raw,'test-scope')
query={where:{'test'=>'value'},order:[['__id','asc']],limit:1000}
reads=0
raw.on_select=-> {reads+=1}
T::ServerReadScope.run('test-scope') do
  assert_equal([],table.select(**query))
  20.times {assert_equal([],table.select(**query))}
  assert_equal(1,reads,'An empty table or repeated query hit SDK again')
  scope=Thread.current[T::ServerReadScope::KEY]
  queries=scope.instance_variable_get(:@queries)
  bytes=scope.instance_variable_get(:@bytes)
  3.times {T::ServerReadScope.refresh!}
  assert_equal(queries,scope.instance_variable_get(:@queries),'Refreshing a retained head inflated the query budget')
  assert_equal(bytes,scope.instance_variable_get(:@bytes),'Refreshing a retained head inflated the byte budget')
  raw.insert('test'=>'value')
  assert_equal([],table.select(**query),'A request scope silently changed without a boundary')
  T::ServerReadScope.refresh!
  assert_equal(1,table.select(**query).size,'Write boundary kept stale data')
  table.insert('test'=>'value')
  assert_equal(2,table.select(**query).size,'Own write did not invalidate cached query')
  other=Thread.new {table.select(**query)}.value
  assert_equal(2,other.size)
end
raw.insert('test'=>'value')
T::ServerReadScope.run('test-scope') {assert_equal(3,table.select(**query).size,'Cache survived its worker operation')}

# A confirmed append to a different immutable document does not discard the
# complete source document already read in this same worker operation.
partition={where:{'operation_key'=>'a'*64},order:[['__id','asc']],limit:1000}
T::ServerReadScope.run('test-scope') do
  table.select(**partition)
  count=reads
  table.insert('operation_key'=>'b'*64)
  table.select(**partition)
  assert_equal(count,reads,'Unrelated own append discarded an immutable partition')
  table.insert('operation_key'=>'a'*64)
  assert_equal(1,table.select(**partition).size,'Same partition was not invalidated')
  raw.insert('operation_key'=>'a'*64)
  table.insert('operation_key'=>'b'*64)
  assert_equal(2,table.select(**partition).size,'A gap in acknowledged IDs hid a concurrent append')
  # A revision check still detects remote changes after our acknowledged write.
  raw.insert('operation_key'=>'a'*64)
  T::ServerReadScope.refresh!
  assert_equal(3,table.select(**partition).size)
end
T::ServerReadScope.run('test-scope') do
  table.select(**partition)
  count=reads
  # No valid acknowledgement means no proof that a partition is unchanged.
  T::ServerReadScope::KEY.then { |key| Thread.current[key].inserted(table,nil) }
  table.select(**partition)
  assert(reads>count,'Unknown acknowledgement retained a snapshot')
end
T::ServerReadScope.run('test-scope') do
  table.select(**partition)
  entry=Thread.current[T::ServerReadScope::KEY].instance_variable_get(:@tables).fetch(table)
  count=reads
  Thread.current[T::ServerReadScope::KEY].inserted(table,{'__id'=>(entry[:revision]+1).to_f,'operation_key'=>'b'*64})
  table.select(**partition)
  assert(reads>count,'Non-integer acknowledgement retained a snapshot')
end
# A lost acknowledgement must invalidate reads just like a successful insert.
T::ServerReadScope.run('test-scope') do
  table.select(**query)
  raw.on_insert=->(*) {raise IOError,'Lost acknowledgement'}
  assert_raises(IOError) {table.insert('test'=>'value')}
  raw.on_insert=nil
  assert_equal(4,table.select(**query).size)
end

Dir.mktmpdir('tournament-read-scope') do |directory|
  raw_authority=TournamentServerPlanTableSupport::Table.new(user:-> {'alice'})
  raw_authority.insert('allowed'=>true)
  authority=T::ServerReadScope::Table.new(raw_authority,'test-scope')
  raw_documents=TournamentServerPlanTableSupport::Table.new(user:-> {'alice'})
  documents=T::ServerReadScope::Table.new(raw_documents,'test-scope')
  journal=T::OperationJournal.new(directory:directory,owner:'alice',backend_identity:'test-scope')
  anchor={'operation_key'=>'a'*64,'tournament_id'=>1,'publication_digest'=>'b'*64,'roster_generation'=>'c'*64}
  verifier=->(*) {authority.select(where:{},order:[['__id','desc']],limit:1).first['allowed']}
  archive=T::ServerPlanArchive.new(table:documents,journal:journal,user:-> {'alice'},verify:verifier)
  raw_documents.on_insert=->(row) {raw_authority.insert('allowed'=>false) if row['part_index']==1}
  T::ServerReadScope.run('test-scope') do
    assert_raises(T::Publication::Invalid) {archive.publish(intent_id:'changing-authority',document:{'large'=>'x'*6000},anchor:anchor)}
  end
  assert_equal('attempted',journal.list.first['status'],'Stale authority was confirmed after the chunk batch')
  T::ServerReadScope.run('test-scope') do
    arguments={where:{},order:[['__id','desc']],limit:1}
    authority.select(**arguments)
    documents.select(**arguments)
    checks=0
    raw_authority.on_select=-> {checks+=1}
    raw_authority.insert('allowed'=>true)
    T::ServerReadScope.refresh!(only:documents)
    assert_equal(0,checks,'An isolated log refresh queried unrelated authority')
    T::ServerReadScope.refresh!
    assert_equal(true,authority.select(**arguments).first['allowed'],'The next authorization did not refresh all authority')
    assert(checks>0)
  end
  T::ServerReadScope.run('test-scope') do
    arguments={where:{},order:[['__id','desc']],limit:1}
    authority.select(**arguments)
    checks=0
    raw_authority.on_select=-> {checks+=1}
    T::ServerReadScope.verify do
      fresh=checks
      authority.select(**arguments)
      3.times {T::ServerReadScope.refresh!}
      assert_equal(fresh,checks,'Nested authorization repeated unchanged local verification')
      raw_authority.insert('allowed'=>false)
      documents.select(where:{'uncached'=>'read'},order:[['__id','asc']],limit:10)
      T::ServerReadScope.refresh!
      assert_equal(false,authority.select(**arguments).first['allowed'],'Intervening server I/O did not invalidate freshness proof')
    end
    raw_authority.insert('allowed'=>true)
    T::ServerReadScope.verify {assert_equal(true,authority.select(**arguments).first['allowed'],'A verification scope escaped its boundary')}
    T::ServerReadScope.verify do
      authority.insert('allowed'=>false)
      count=checks
      T::ServerReadScope.refresh!
      assert(checks>count,'A write did not break nested freshness')
    end
  end
end
puts 'PASS request-local reads, worker isolation, fresh write boundaries, own/uncertain insertion invalidation and changed authority during a multipart write'
