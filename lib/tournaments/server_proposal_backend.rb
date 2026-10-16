require_relative 'server_workspace'
require_relative 'proposal_notice'

module GameRoomTournaments
  # Notification adapter for the actual append-only SDK protocol. All methods
  # run on a worker and use fresh server evidence, never notification claims.
  class ServerProposalBackend
    def initialize(workspace:, busy:, changed: ->(_notice) {})
      @workspace,@busy,@changed=workspace,busy,changed
    end

    def lookup_proposal(notice:)
      notice=ProposalNotice.metadata(notice)
      raise ProposalNotice::Stale,'Different backend' unless notice['backend_identity']==@workspace.backend_identity
      source=@workspace.coordination_source_on_worker(publication_ref:notice['publication_ref'])
      raise ProposalNotice::Stale,'Different schedule' unless source['candidate']['schedule_id']==notice['schedule_id']
      raise ProposalNotice::Stale,'Use the match list to return to a table' if notice['stage']=='enter'
      snapshot=@workspace.proposal_on_worker(publication_ref:notice['publication_ref'],match_id:notice['match_id'],leg:notice['leg'])
      unless %w[awaiting_consent consented].include?(snapshot['state']) && snapshot['token']==notice['token']
        raise ProposalNotice::Stale,'Proposal changed or expired'
      end
      Publication::Data.freeze_tree({'status'=>'confirmed','metadata'=>notice,'sender'=>snapshot.fetch('sender'),
        'players'=>snapshot.fetch('players'),'accepted'=>snapshot.fetch('accepted'),'revision'=>snapshot.fetch('token'),
        'window'=>snapshot.fetch('window')})
    end

    def respond_proposal(notice:,expected_revision:,accept:)
      proof=lookup_proposal(notice:notice)
      raise ProposalNotice::Stale,'Proposal changed' unless proof['revision']==expected_revision
      raise ProposalNotice::Stale,'Leave the current table first' if accept && @busy.call
      response=@workspace.proposal_on_worker(publication_ref:notice['publication_ref'],match_id:notice['match_id'],leg:notice['leg'],
        action:accept ? 'accept' : 'decline',token:notice['token'],intent_id:SecureRandom.uuid,
        guard:-> {!accept || !@busy.call})
      @changed.call(notice)
      {'consented'=>:confirmed,'awaiting_consent'=>:awaiting_consent,'declined'=>:declined}.fetch(response['state'],:conflict)
    end

    module WorkerReads
      %i[lookup_proposal respond_proposal].each do |name|
        define_method(name) do |**arguments|
          @workspace.read_operation { super(**arguments) }
        end
      end
    end
    prepend WorkerReads
  end
end
