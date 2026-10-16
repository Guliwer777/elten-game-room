require_relative '../support/tournament_public_service'
require_relative '../support/host_source'
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../../lib/tournaments/server_schema'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions
tables = T::ServerSchema::PROPOSED_TABLES
assert_equal(T::Publication::COLUMNS.sort, tables['tournament_announcements']['columns'].keys.sort)
assert_equal(%w[account amendment_json kind operation_key pairing_generation partner publication_generation tournament_id], tables['tournament_registrations']['columns'].keys.sort)
assert(tables.values.all? { |row| row['permissions'] == %w[select insert] }, 'Accepted rows must not be edited or deleted')
original = {'existing_table' => {'columns' => {'value' => 'integer'}}}
merged = T::ServerSchema.merge(original)
assert_equal(['existing_table'], original.keys)
assert_equal(original['existing_table'], merged['existing_table'])
assert_equal(merged, T::ServerSchema.merge(merged))
assert_raises(T::Publication::Invalid) { T::ServerSchema.merge({'tournament_announcements' => {'columns' => {}}}) }
definition = Programs::ServerAppDefinition.new(uuid: '468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80', tables: merged, protected: true, notifications: true)
assert_equal(merged, definition.tables)
assert_equal(true, definition.protected?)
assert_equal(true, definition.notifications?)
publication = T::Publication.from_draft(**params.reject { |key, _| key == :intent_id }.merge(publication_key: 'schema-test', registry: GameRoomGames::CATALOG)).to_row
registration = T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'schema-join')
[[publication, 'tournament_announcements'], [registration, 'tournament_registrations']].each do |values, name|
  values.each do |key, value|
    type = tables[name]['columns'].fetch(key)
    if type == 'integer'
      assert(value.is_a?(Integer), key)
    else
      assert(value.is_a?(String) && value.bytesize <= type.split(':').last.to_i, key)
    end
  end
end
puts 'PASS proposed online schema: actual publication/join payloads, append-only permissions, native declaration, idempotent additive merge and conflict rejection; no server write'
