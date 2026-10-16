# encoding: UTF-8
require_relative 'proposal_notice_inbox'
require_relative 'proposal_notice_dialog'
require_relative 'proposal_notice_publisher'
require_relative 'proposal_notice_journal'
require_relative 'tournament_start_runtime'
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomTournaments
  module ProposalNotificationsRuntime
    include TournamentStartRuntime
    using GameRoomLocalization::Translations

    # Only application composition can install this port. Notification metadata
    # never chooses a reader, URL or backend. No remote port is enabled by default.
    def configure_tournament_proposals(backend:, context:, clock:)
      service = ProposalNotice.new(backend: backend, context: context, clock: clock)
      stop_tournament_proposals(include_starts:false)
      @tournament_proposal_service = service
      @tournament_proposal_inbox = ProposalNoticeInbox.new(service: service,
        worker: GameRoomBackground::Work.new(runtime: app_runtime))
    end

    def stop_tournament_proposals(include_starts:true)
      stop_tournament_starts if include_starts
      @tournament_proposal_inbox&.close
      @tournament_proposal_inbox = @tournament_proposal_service = nil
    end

    def tournament_proposal_service; @tournament_proposal_service; end
    def tournament_pending_invitations; @tournament_proposal_inbox&.pending || []; end
    def forget_tournament_invitation(token)
      ids=@tournament_proposal_inbox&.forget(token) || []
      EltenAPI::NotificationService.revoke_active_notifications(ids) unless ids.empty?
    end

    # Worker only. Supported SDK notification transport, gated by a trusted
    # proposal lookup. The default missing backend never reaches send_notification.
    def send_tournament_proposal(metadata)
      service = @tournament_proposal_service
      raise ProposalNotice::Unavailable, 'Shared proposals are not connected' unless service
      account = Publication::Data.account(Session.name).downcase
      notice = ProposalNotice.metadata(metadata)
      scope = Digest::SHA256.hexdigest(JSON.generate([account, notice['backend_identity']]))
      journal = ProposalNoticeJournal.new(program: self, path: "tournament-notice-deliveries-#{scope}.json")
      transaction = journal.method(:update)
      ProposalNoticePublisher.new(service: service, sender: -> { Session.name }, transaction: transaction,
        send: ->(value, closes) { send_notification(value['recipient'], type: ProposalNotice::TYPE, metadata: value,
          expires_in: service.remaining_seconds(closes)) }).deliver(metadata: notice)
    end

    def tournament_proposal_presentation(notification)
      cached = @tournament_proposal_inbox&.verified(notification.id)
      metadata = ProposalNotice.metadata(notification.metadata.to_h)
      valid = cached && cached[0]['metadata'] == metadata && cached[1] == notification.sender.to_s.downcase &&
        notification.app_uuid.to_s.downcase == server_app_uuid.to_s.downcase &&
        @tournament_proposal_service.presentable?(cached[0])
      body = valid ? GameRoomContent.utf8(_("Tournament match: %{players}")) % {players: cached[0]['players'].join(' — ')} : GameRoomContent.utf8(_("This match invitation is no longer available."))
      presentation = notification.presentation(title: _("Game invitation"), body: body,
        sound: valid && normalized_settings['invitation_sounds'] ? 'notice' : nil, action: valid ? ProposalNotice::ACTION : nil)
      presentation.suppress_default! unless valid
      if valid && normalized_settings['invitation_sounds'] && respond_to?(:play_sound_from_asset)
        presentation.extend(GameRoomUI::NotificationSound)
        presentation.game_room_notice_player = -> {
          volume = GameRoomPreferences.sound_volume(normalized_settings, 'notice')
          play_sound_from_asset('notice', volume: volume) if volume > 0
        }
      end
      presentation
    rescue Publication::Invalid
      notification.presentation(title: _("Game invitation"), body: _("This match invitation is no longer available."), sound: nil).suppress_default!
    end

    def receive_tournament_proposal(notification)
      return unless @tournament_proposal_inbox && notification.app_uuid.to_s.downcase == server_app_uuid.to_s.downcase
      return if notification.respond_to?(:revoked) && notification.revoked
      @tournament_proposal_inbox.receive(id: notification.id, metadata: notification.metadata.to_h, sender: notification.sender)
    end

    def tournament_proposals_tick
      tournament_starts_tick
      return unless @tournament_proposal_inbox
      @tournament_proposal_inbox.tick.each do |id, _proof|
        # The active host notification is retained by ELTEN. Re-read its current
        # revoked/type state instead of retaining a caller-supplied object.
        rows = EltenAPI::NotificationService.active_notifications
        row = rows.find { |value| value.id.to_i == id && value.cat.to_s == 'app' && value.app_uuid.to_s.downcase == server_app_uuid.to_s.downcase }
        next unless row && row.revoked != true
        notification = Programs.app_notification_from(row)
        next unless notification.type == ProposalNotice::TYPE
        present_deferred_contact_notification(notification)
      end
      revoked=@tournament_proposal_inbox.take_revoked
      EltenAPI::NotificationService.revoke_active_notifications(revoked) unless revoked.empty?
    rescue StandardError => error
      Log.warning("Tournament notification delivery failed: #{error.class}: #{error.message}") if defined?(Log)
    end
  end
end
