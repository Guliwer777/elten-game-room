require_relative 'publication'
module GameRoomTournaments
  # Publication and registration schema included in the local application
  # declaration. Loading this file never applies a schema to the server.
  module ServerSchema
    PROPOSED_TABLES = Publication::Data.freeze_tree({
      'tournament_announcements' => {
        'visibility' => 'public',
        'columns' => {
          'publication_key' => 'string:64', 'schema_version' => 'integer',
          'title' => 'string:1024', 'game' => 'string:32', 'rules' => 'string:2048',
          'settings_json' => 'string:2048', 'schedule_json' => 'string:2048',
          'registration_opens_at' => 'integer', 'registration_closes_at' => 'integer', 'timezone' => 'string:64'
        },
        'permissions' => %w[select insert],
        'indexes' => [['publication_key'], ['registration_closes_at']],
        'limits' => {'max_select_limit' => 1000}
      },
      'tournament_registrations' => {
        'visibility' => 'public',
        'columns' => {'tournament_id' => 'integer', 'operation_key' => 'string:64', 'kind' => 'string:16',
          'account' => 'string:256', 'partner' => 'string:256', 'pairing_generation' => 'string:64',
          'publication_generation' => 'string:64', 'amendment_json' => 'string:2048'},
        'permissions' => %w[select insert],
        'indexes' => [['tournament_id'], ['operation_key']],
        'limits' => {'max_select_limit' => 1000}
      },
      'tournament_plan_documents' => {
        'visibility' => 'public',
        'columns' => {'operation_key' => 'string:64', 'tournament_id' => 'integer',
          'publication_digest' => 'string:64', 'roster_generation' => 'string:64',
          'document_digest' => 'string:64', 'part_count' => 'integer', 'part_index' => 'integer', 'payload' => 'string:2048'},
        'permissions' => %w[select insert], 'indexes' => ['operation_key'], 'limits' => {'max_select_limit' => 1000}
      }
    })
    def self.merge(existing)
      raise Publication::Invalid, :invalid_schema unless existing.is_a?(Hash)
      PROPOSED_TABLES.each do |name, definition|
        if existing.key?(name) && !existing[name].eql?(definition)
          raise Publication::Invalid, :schema_conflict
        end
      end
      existing.merge(PROPOSED_TABLES)
    end
  end
end
