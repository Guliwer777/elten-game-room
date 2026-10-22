module GameRoomTournaments
  # Authenticated registration operations only. Invitations never join a
  # player, reserve a seat or affect a schedule/binding hash.
  module RegistrationInvitations
    module_function
    def project(rows)
      active, invited = {}, {}
      rows.sort_by { |row| [row['__insertion_time'], row['__id']] }.each do |row|
        id, actor = row['canonical_tournament_id'], row['__insertion_user'].downcase
        account = row['kind'] == 'removal' ? row['account'] : actor
        case row['kind']
        when 'join'
          active[[id, account]] = true
          invited[[id, account]]['resolved'] = true if invited[[id, account]]
        when 'withdrawal', 'removal'
          active.delete([id, account])
        when 'invitation'
          key = [id, row['account'].downcase]
          next if active[key] || invited.key?(key)
          invited[key] = {'tournament_id' => id, 'account' => key.last, 'username' => row['account'],
            'operation_key' => row['operation_key'], 'status' => 'pending', 'invited_at' => row['__insertion_time']}
        when 'invite_declined'
          entry = invited[[id, actor]]
          entry['status'] = 'declined' if entry && entry['operation_key'] == row['operation_key']
        end
      end
      invited.values.sort_by { |entry| [entry['tournament_id'], entry['account']] }
    end
  end
end
