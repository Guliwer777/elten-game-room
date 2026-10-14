require_relative 'proposal_notice'

module GameRoomTournaments
  # Finite worker operation. A local durable claim prevents resending an
  # uncertain notification. This is not a global player reservation/claim.
  class ProposalNoticePublisher
    LIMIT = 128
    def initialize(service:, sender:, transaction:, send:)
      @service, @sender, @transaction, @send = service, sender, transaction, send
    end

    def deliver(metadata:)
      sender = Publication::Data.account(@sender.call).downcase
      proof = @service.inspect(metadata: metadata, sender: sender, delivery: true)
      notice = proof['metadata']
      raise ProposalNotice::Stale, 'Recipient already accepted' if proof['accepted'].include?(notice['recipient'])
      key = Digest::SHA256.hexdigest(JSON.generate([sender, notice]))
      descriptor = {'sender'=>sender, 'metadata'=>notice, 'revision'=>proof['revision']}
      permitted = false
      previous = nil
      @transaction.call do |state|
        validate!(state)
        if state['operations'].key?(key)
          raise ProposalNotice::Stale, 'Delivery descriptor changed' unless state['operations'][key]['descriptor'] == descriptor
          previous = state['operations'][key]['state']
        else
          raise ProposalNotice::Unavailable, 'Notification journal limit reached' if state['operations'].size >= LIMIT
          state['operations'][key] = {'descriptor'=>descriptor, 'state'=>'attempted'}
          permitted = true
        end
      end
      return previous == 'sent' ? :sent : :confirmation_pending unless permitted
      # A readiness/account change after the claim still blocks delivery, but
      # never restores permission to resend this same proposal automatically.
      raise ProposalNotice::Stale, 'Proposal changed before delivery' unless
        @service.inspect(metadata: notice, sender: sender, delivery: true) == proof && Publication::Data.account(@sender.call).downcase == sender
      expires = proof['window']['closes']
      result = @send.call(notice, expires)
      raise ProposalNotice::Unavailable, 'Notification write not confirmed' unless result == true
      @service.assert_context!
      @transaction.call do |state|
        validate!(state)
        entry = state['operations'][key]
        raise ProposalNotice::Stale, 'Delivery journal changed' unless entry && entry['descriptor'] == descriptor
        entry['state'] = 'sent'
      end
      :sent
    end

    private

    def validate!(state)
      unless state.is_a?(Hash) && state.keys.sort == %w[operations version] && state['version'] == 1 &&
          state['operations'].is_a?(Hash) && state['operations'].size <= LIMIT
        raise ProposalNotice::Unavailable, 'Notification journal is corrupt'
      end
      state['operations'].each do |key, row|
        ServerPlanDocument.digest!(key)
        unless row.is_a?(Hash) && row.keys.sort == %w[descriptor state] && %w[attempted sent].include?(row['state']) &&
            row['descriptor'].is_a?(Hash) && row['descriptor'].keys.sort == %w[metadata revision sender]
          raise ProposalNotice::Unavailable, 'Notification journal is corrupt'
        end
        notice = ProposalNotice.metadata(row['descriptor']['metadata'])
        sender = Publication::Data.account(row['descriptor']['sender']).downcase
        Publication::Data.text!(row['descriptor']['revision'], bytes: 256)
        raise ProposalNotice::Unavailable, 'Notification journal is corrupt' unless key == Digest::SHA256.hexdigest(JSON.generate([sender, notice]))
      end
    end
  end
end
