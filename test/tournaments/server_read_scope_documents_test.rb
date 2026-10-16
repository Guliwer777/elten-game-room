require_relative '../support/assertions'
require_relative '../support/tournament_server_plan_table'
require_relative '../../lib/tournaments/server_read_scope'
require_relative '../../lib/tournaments/server_document_rows'
include GameRoomTest::Assertions
T=GameRoomTournaments
raw=TournamentServerPlanTableSupport::Table.new(user:-> {'Alice'})
keys=['a'*64,'b'*64,'c'*64]
1205.times{|i|raw.insert('operation_key'=>keys[i%2])}
raw.insert('operation_key'=>keys.last)
original=raw.method(:select)
reads=0
raw.define_singleton_method(:select) do |**args|
  reads+=1
  original.call(**args).first(17) # A short SDK page is not EOF.
end
table=T::ServerReadScope::Table.new(raw,'documents')
read=->(where,**options){T::ServerDocumentRows.read(table,where:where,**options)}
T::ServerReadScope.run('documents') do
  all=read.call({'operation_key'=>{'in'=>keys.first(2)}})
  assert_equal(1205,all.size)
  before=reads
  assert_equal(603,read.call({'operation_key'=>keys.first},author:'ALICE').size)
  assert_equal([],read.call({'operation_key'=>keys.first},author:'Bob'))
  assert_equal(before,reads,'A complete batch did not serve a narrower document read')
  assert(all.frozen? && all.first.frozen?)
  assert_equal(1,read.call({'operation_key'=>keys.last}).size,'Unrelated key was treated as absent')
  before=reads
  union=read.call({'operation_key'=>{'in'=>keys}})
  assert_equal(1206,union.size,'Several complete batches did not cover their union')
  assert_equal(1206,union.map{|row|row['__id']}.uniq.size,'Overlapping batches duplicated evidence')
  assert_equal(before,reads,'A covered union caused another SDK query')
  raw.insert('operation_key'=>keys.first)
  T::ServerReadScope.refresh!
  assert_equal(604,read.call({'operation_key'=>keys.first}).size,'A remote append left stale complete evidence')
  table.insert('operation_key'=>keys.first)
  assert_equal(605,read.call({'operation_key'=>keys.first}).size,'Own append left stale complete evidence')
  raw.on_insert=->(*){raise IOError,'Acknowledgement lost'}
  assert_raises(IOError){table.insert('operation_key'=>keys.first)}
  raw.on_insert=nil
  assert_equal(606,read.call({'operation_key'=>keys.first}).size,'Uncertain append left stale evidence')
  assert_equal(3,read.call({'operation_key'=>keys.first},after_id:1206).size,'Cursor was ignored by batch reuse')
end
T::ServerReadScope.run('documents') do
  calls=0
  raw.on_select=-> {calls+=1;raise IOError,'Later page failed' if calls==5}
  assert_raises(IOError){read.call({'operation_key'=>keys.first})}
  raw.on_select=nil
  assert_equal(606,read.call({'operation_key'=>keys.first}).size,'An incomplete read was cached as complete')
end
before=reads
T::ServerReadScope.run('other-account'){read.call({'operation_key'=>keys.first})}
assert(reads>before,'Another identity reused the first scope')
puts 'PASS complete document batches: short pages, subset/author/cursor isolation, frozen copies, remote/own/uncertain writes and late read failures'
