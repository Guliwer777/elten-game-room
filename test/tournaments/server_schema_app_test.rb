require_relative '../support/settings_widget'
require_relative '../../lib/tournaments/server_schema'

GameRoomTournaments::ServerSchema::PROPOSED_TABLES.each do |name, schema|
  assert(EltenGameRoom::SERVER_TABLES.fetch(name) == schema, "Missing tournament table #{name}")
end
[GameRoomGames::KrowaServerSchema::TABLES, GameRoomStatistics::Schema::TABLES,
 GameRoomPresence::Schema::TABLES].each do |existing|
  existing.each { |name, schema| assert(EltenGameRoom::SERVER_TABLES.fetch(name) == schema, "Existing schema changed: #{name}") }
end
assert(EltenGameRoom::SERVER_TABLES.fetch(GameRoomTableWatch::TABLE) == GameRoomTableWatch::SCHEMA, 'Watch table changed')
assert(EltenGameRoom::SERVER_TABLES.key?('game_room_users'), 'User table missing')
assert(EltenGameRoom::SERVER_TABLES.key?('table_activity'), 'Activity table missing')
puts 'PASS local app schema: tournament tables declared alongside unchanged existing tables; no server update'
