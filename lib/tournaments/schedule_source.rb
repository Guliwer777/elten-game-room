# encoding: UTF-8
require_relative 'registration_projection'

module GameRoomTournaments
  # Wspólna obserwacja przed wyborem planera osób albo niepodzielnych ekip.
  module ScheduleSource
    Data = Publication::Data
    Invalid = Publication::Invalid
    module_function

    def build(projection:, publication_ref:, backend_identity:, observed_at:)
      unless RegistrationProjection === projection && projection.instance_of?(RegistrationProjection) && projection.frozen?
        raise Invalid, :invalid_projection
      end
      data = projection.to_h
      raise Invalid, :invalid_projection unless Hash === data && data.frozen?
      raise Invalid, :invalid_observed_at unless Data.integer?(observed_at)
      unless Data.text?(backend_identity) && backend_identity.bytesize.between?(1, 4096) &&
          !backend_identity.match?(/[[:cntrl:]\u2028\u2029]/)
        raise Invalid, :invalid_backend_identity
      end
      backend_identity = String.new(backend_identity).encode(Encoding::UTF_8)
      publication_ref = reference(publication_ref)
      validate_diagnostics!(data)
      row = data.fetch('announcements').find do |item|
        item.fetch('__insertion_user').downcase == publication_ref.fetch('author') &&
          item.fetch('publication_key') == publication_ref.fetch('publication_key')
      end
      raise Invalid, :missing_publication unless row
      raise Invalid, :registration_open if observed_at < row.fetch('registration_closes_at')
      settings = StrictJson.parse(row.fetch('settings_json'), max_nesting: 8)
      # Older simplified forms stored Groups without the hidden advancement
      # fields. Use the agreed automatic policy only for that complete omission.
      if settings['format'] == 'groups_knockout' && Publication::ADVANCEMENT_SETTINGS.none? { |key| settings[key] }
        settings = settings.merge('group_advancement' => 'automatic_cross_groups_v1')
      end
      unless settings.fetch('format') == 'round_robin' ||
          (settings.fetch('format') == 'groups_knockout' &&
            (['automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(settings['group_advancement']) || Publication::GROUP_SETTINGS.all? { |key| settings[key].is_a?(Integer) }))
        raise Invalid, :unsupported_format
      end
      schedule = StrictJson.parse(row.fetch('schedule_json'), max_nesting: 8)
      members = data.fetch('members').select { |member| member.fetch('tournament_id') == row.fetch('__id') }
        .sort_by { |member| member.fetch('account') }
      {row: row, settings: settings, schedule: schedule, members: members,
        publication_ref: publication_ref, backend_identity: backend_identity}
    end

    def reference(value)
      unless Hash === value && value.size == 2 && value.key?('author') && value.key?('publication_key')
        raise Invalid, :invalid_publication_ref
      end
      {'author' => Data.account(value.fetch('author')).downcase,
        'publication_key' => String.new(Data.key!(value.fetch('publication_key'))).encode(Encoding::UTF_8)}
    rescue Invalid
      raise Invalid, :invalid_publication_ref
    end

    # Legalne outside_window pozostaje związane z odrzuconym dowodem operacji.
    def validate_diagnostics!(data)
      diagnostics = data.fetch('diagnostics')
      operations = data.fetch('operations').to_h { |op| [op.values_at('account', 'operation_key'), op] }
      healthy = diagnostics.fetch('registrations').all? do |item|
        operation = operations[item.values_at('account', 'key')]
        item.fetch('code') == 'outside_window' && operation &&
          item.fetch('ids').length == 1 &&
          (item.fetch('ids') - (operation.fetch('record_ids') - operation.fetch('eligible_ids'))).empty?
      end
      unless diagnostics.fetch('announcements').empty? && healthy
        raise Invalid, :unresolved_source_diagnostics
      end
    end
  end
end
