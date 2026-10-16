require 'json'
require_relative '../../lib/tournaments/server_schema'

# Preparation only. No client, credentials, SDK registration or migration.
puts JSON.pretty_generate({
  'tables' => GameRoomTournaments::ServerSchema::PROPOSED_TABLES,
  'notifications' => true,
  'max_text_field_bytes' => 2048,
  'coordination' => 'not_provided_by_row_tables',
  'deployment' => 'official_application_owner_review_required'
})
