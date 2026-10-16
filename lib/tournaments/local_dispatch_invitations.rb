require_relative 'local_fixed_team_admission'
module GameRoomTournaments
  class LocalDispatchInvitations < LocalFixedTeamAdmission
    def self.validate!(execution, core)
      invitations = core['invitations']
      raise Publication::Invalid, :sandbox_corrupt unless invitations.is_a?(Hash) && invitations.size <= execution['request']['players'].size
      invitations.each do |account, row|
        person = execution['request']['players'].find { |value| value['account'] == account }
        binding = execution['target']['binding']
        unless person && account != core['owner'].downcase && row.is_a?(Hash) &&
            row.keys.sort == (%w[binding_digest created_at epoch expires_at id native_uuid recipient sender table_id] +
              (row.key?('replaces_id') ? ['replaces_id'] : [])).sort &&
            (!row.key?('replaces_id') || (Data.integer?(row['replaces_id'], 1) && row['replaces_id'] != row['id'])) &&
            Data.integer?(row['id'], 1) && row['native_uuid'] == core['id'] && row['table_id'] == binding['table_id'] &&
            row['sender'] == core['owner'] && row['recipient'] == person['username'] &&
            row['binding_digest'] == C.digest(binding) && Data.integer?(row['epoch'], 1) && row['epoch'] <= execution['epoch'] &&
            Data.integer?(row['created_at']) && row['expires_at'].is_a?(Integer) &&
            row['expires_at'] > row['created_at'] && row['expires_at'] <= row['created_at'] + 120 && row['expires_at'] <= execution['request']['window']['closes']
          raise Publication::Invalid, :sandbox_corrupt
        end
      end
    end
    def send_to_available(renew: nil)
      if renew
        unless renew.is_a?(Hash) && renew.keys.sort == %w[account invitation_id] && Data.integer?(renew['invitation_id'], 1)
          raise Publication::Invalid, :invalid_renewal
        end
        Data.account(renew['account'])
      end
      @record_reader.call(true)
      @port.transaction do |document|
        execution = execution!(document)
        raise C::Blocked, :not_coordinator unless execution['coordinator'] == actor
        raise C::Blocked, :stale_grant unless active?(execution)
        now = @clock.call
        intent = execution['record_intent']
        unless LocalDispatchContract.policy(document, intent) && @request['players'].all? { |person| LocalDispatchContract.ready(document, intent, person['account'], now)['state'] == 'ready' }
          raise C::Blocked, :participants_unavailable
        end
        core = core!(document, execution)
        if renew
          raise C::Blocked, :already_started if execution['start']
          prior = core['invitations'][renew['account']]
          raise C::Blocked, :invitation_changed unless prior && (prior['id'] == renew['invitation_id'] || prior['replaces_id'] == renew['invitation_id'])
          raise C::Blocked, :already_entered if core['participants'].key?(renew['account'])
          if prior['id'] == renew['invitation_id'] && prior['expires_at'] > now
            raise C::Blocked, :invitation_not_expired
          end
        end
        before = @storage.copy(core['invitations'])
        LocalFixedTeamMoves.with_core(core, execution, owner: core['owner'], require_session: false) do |tx, transport, _table, _repository, _session|
          @request['players'].each do |person|
            next if renew && person['account'] != renew['account']
            next if person['account'] == actor || core['participants'].key?(person['account'])
            metadata = {'binding_digest' => C.digest(execution['target']['binding']), 'epoch' => execution['epoch'],
              'table_id' => execution['target']['binding']['table_id'], 'created_at' => now,
              'expires_at' => [now + 120, @request['window']['closes']].min}
            metadata['replaces_id'] = renew['invitation_id'] if renew
            result = transport.invite_user(table_id: metadata['table_id'], user: person['username'], metadata: metadata)
            raise C::Blocked, :invitation_not_confirmed unless result.is_a?(Hash)
          end
          core.replace(@storage.copy(tx.dump['cores'].first))
        end
        effect = detached(core['invitations'])
        @storage.write(document, receipt: effect) unless before.eql?(core['invitations'])
        effect
      end
    end
  end
end
