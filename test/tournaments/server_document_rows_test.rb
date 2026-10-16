require_relative '../../lib/tournaments/server_document_rows'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/assertions'
include GameRoomTest::Assertions
T = GameRoomTournaments
owner = 'Alice'
table = TournamentServerPlanTableSupport::Table.new(user: -> {owner})
1205.times { |index| table.insert('operation_key'=>'a'*64, 'payload'=>index.to_s) }
rows = T::ServerDocumentRows.read(table, where: {'operation_key'=>'a'*64})
assert_equal(1205, rows.size)
assert_equal((1..1205).to_a, rows.map { |row|row['__id'] })
assert_equal((1201..1205).to_a,T::ServerDocumentRows.read(table,where:{'operation_key'=>'a'*64},after_id:1200).map{|row|row['__id']})
assert_equal([],T::ServerDocumentRows.read(table,where:{'operation_key'=>'a'*64},after_id:1205))
assert_raises(T::Publication::Invalid){T::ServerDocumentRows.read(table,where:{},after_id:-1)}
owner = 'Mallory'
table.insert('operation_key'=>'a'*64, 'payload'=>'foreign')
assert_equal(1205, T::ServerDocumentRows.read(table, where: {'operation_key'=>'a'*64}, author:'alice').size)

# The host may return less than the requested limit. Stop at the captured ID,
# not at an arbitrarily short page; ignore rows appended after that boundary.
native_select = table.method(:select)
table.define_singleton_method(:select) do |**query|
  result = native_select.call(**query.merge(limit:[query[:limit], 37].min))
  insert('operation_key'=>'a'*64, 'payload'=>'concurrent') if query[:order].first.last == 'desc'
  result
end
assert_equal(1206, T::ServerDocumentRows.read(table, where: {'operation_key'=>'a'*64}).size)
assert_equal((1101..1207).to_a,T::ServerDocumentRows.read(table,where:{'operation_key'=>'a'*64},after_id:1100).map{|row|row['__id']})
guards = 0
assert_raises(IOError) do
  T::ServerDocumentRows.read(table, where: {'operation_key'=>'a'*64}, guard: -> { guards+=1; raise IOError if guards==4 })
end
table.define_singleton_method(:select) { |**_query| [{}] }
assert_raises(T::Publication::Invalid) { T::ServerDocumentRows.read(table, where: {}) }
puts 'PASS document pagination: 1205 rows, short pages, captured upper ID, authenticated author, invalid pages and context guard'
