module GameRoomTournaments
  module PublicInvitationOperations
    Data = Publication::Data
    def invite(tournament_id:, recipient:, intent_id:)
      recipient = Data.account(recipient)
      invitation_change(tournament_id, 'invitation', intent_id) do |row, data|
        raise PublicService::Error, :not_organizer unless row['__insertion_user'].downcase == @journal.owner
        raise PublicService::Error, :already_registered if data['members'].any? { |person| person['tournament_id'] == row['__id'] && person['account'] == recipient.downcase }
        raise PublicService::Error, :already_invited if data.fetch('invitations', []).any? { |entry| entry['tournament_id'] == row['__id'] && entry['account'] == recipient.downcase }
        settings = JSON.parse(row['settings_json'])
        count = data['members'].count { |person| person['tournament_id'] == row['__id'] }
        raise PublicService::Error, :participant_limit_reached if settings['participant_limit'] && count >= settings['participant_limit']
        {'account' => recipient, 'operation_key' => SecureRandom.uuid}
      end
    end

    def decline_invitation(tournament_id:, invitation_key:, intent_id:)
      invitation_change(tournament_id, 'invite_declined', intent_id) do |row, data|
        entry = data.fetch('invitations', []).find do |item|
          item['tournament_id'] == row['__id'] && item['account'] == @journal.owner && item['operation_key'] == invitation_key
        end
        raise PublicService::Error, :unknown_invitation unless entry
        raise PublicService::Error, :already_registered if data['members'].any? { |person| person['tournament_id'] == row['__id'] && person['account'] == @journal.owner }
        {'account' => @journal.owner, 'operation_key' => invitation_key}
      end
    end

    private

    def invitation_change(id, kind, intent)
      raise PublicService::Error, :invalid_tournament_id unless Data.integer?(id, 1)
      previous = boundary { @journal.find(kind: kind, intent_id: intent) }
      return reconcile_record(previous, snapshot) if previous && previous['status'] != 'prepared'
      view = snapshot
      data = view.fetch(:model).to_h
      row = data['announcements'].find { |item| item['alias_ids'].include?(id) }
      raise PublicService::Error, :unknown_tournament unless row
      now = boundary { @clock.call }
      raise PublicService::Error, :not_open unless TournamentTiming.registration_open?(row, now)
      before_tournament_start!(row)
      extra = yield row, data
      extra['operation_key'] = previous['values']['operation_key'] if previous && kind == 'invitation'
      values = RegistrationProjection.join_values(tournament_id: row['__id'], operation_key: extra.fetch('operation_key')).merge(extra).merge('kind' => kind)
      record = previous || boundary { @journal.prepare(kind: kind, intent_id: intent, values: values) }
      raise PublicService::Error, :source_changed unless record['values'] == values
      attempt(record)
    end
  end
end
