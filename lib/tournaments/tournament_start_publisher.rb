require_relative 'tournament_start_notice'

module GameRoomTournaments
  class TournamentStartPublisher
    LIMIT=512
    def initialize(service:,sender:,transaction:,send:)
      @service,@sender,@transaction,@send=service,sender,transaction,send
    end
    def deliver(metadata:)
      sender=Publication::Data.account(@sender.call).downcase
      proof=@service.inspect(metadata:metadata,sender:sender,delivery:true)
      notice=proof['metadata']
      key=Digest::SHA256.hexdigest(JSON.generate([sender,notice]))
      descriptor={'sender'=>sender,'metadata'=>notice}
      claimed=false
      previous=nil
      @transaction.call do |state|
        validate!(state)
        if (entry=state['operations'][key])
          raise ProposalNotice::Stale,'Start delivery changed' unless entry['descriptor']==descriptor
          previous=entry['state']
        else
          raise ProposalNotice::Unavailable,'Start journal limit reached' if state['operations'].size>=LIMIT
          state['operations'][key]={'descriptor'=>descriptor,'state'=>'attempted'}
          claimed=true
        end
      end
      return previous=='sent' ? :sent : :confirmation_pending unless claimed
      unless @service.inspect(metadata:notice,sender:sender,delivery:true)==proof && Publication::Data.account(@sender.call).downcase==sender
        raise ProposalNotice::Stale,'Start source changed before delivery'
      end
      raise ProposalNotice::Unavailable,'Start delivery not confirmed' unless @send.call(notice,proof['expires_at'])==true
      @service.assert_context!
      @transaction.call do |state|
        validate!(state)
        entry=state['operations'][key]
        raise ProposalNotice::Stale,'Start journal changed' unless entry && entry['descriptor']==descriptor
        entry['state']='sent'
      end
      :sent
    end
    private
    def validate!(state)
      unless state.is_a?(Hash) && state.keys.sort==%w[operations version] && state['version']==1 && state['operations'].is_a?(Hash) && state['operations'].size<=LIMIT
        raise ProposalNotice::Unavailable,'Start journal corrupt'
      end
      state['operations'].each do |key,entry|
        ServerPlanDocument.digest!(key)
        unless entry.is_a?(Hash) && entry.keys.sort==%w[descriptor state] && %w[attempted sent].include?(entry['state']) &&
            entry['descriptor'].is_a?(Hash) && entry['descriptor'].keys.sort==%w[metadata sender]
          raise ProposalNotice::Unavailable,'Start journal corrupt'
        end
        notice=TournamentStartNotice.metadata(entry['descriptor']['metadata'])
        sender=Publication::Data.account(entry['descriptor']['sender']).downcase
        raise ProposalNotice::Unavailable,'Start journal corrupt' unless key==Digest::SHA256.hexdigest(JSON.generate([sender,notice]))
      end
    end
  end
end
