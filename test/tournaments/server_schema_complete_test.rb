require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/native_room_harness'
require_relative '../../lib/tournaments/server_schema'
require_relative '../../lib/tournaments/server_plan_document'
include GameRoomTest::Assertions
T=GameRoomTournaments
tables=T::ServerSchema::PROPOSED_TABLES
assert_equal(T::Publication::COLUMNS.sort,tables['tournament_announcements']['columns'].keys.sort)
assert_equal(%w[account amendment_json kind operation_key pairing_generation partner publication_generation tournament_id],
  tables['tournament_registrations']['columns'].keys.sort)
assert_equal(T::ServerPlanDocument::FIELDS.sort,tables['tournament_plan_documents']['columns'].keys.sort)
tables.each_value do |table|
  assert_equal(%w[select insert],table['permissions'])
  table['columns'].each_value{|type|assert(type=='integer' || type.match?(/\Astring:(\d+)\z/) && type.split(':').last.to_i<=2048)}
end
existing={'ordinary_table'=>{'columns'=>{'id'=>'integer'}}}
merged=T::ServerSchema.merge(existing)
assert_equal(existing['ordinary_table'],merged['ordinary_table'])
assert_equal(1,existing.size,'Preparation must not mutate existing schema')
assert_raises(T::Publication::Invalid){T::ServerSchema.merge({'tournament_registrations'=>{}})}
puts 'PASS prepared server schema: complete publication/events/documents, tested text budgets, append-only permissions, preserved existing tables and explicit conflict refusal'
