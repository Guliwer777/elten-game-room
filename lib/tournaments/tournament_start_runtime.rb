# encoding: UTF-8
require_relative 'tournament_start_publisher'
require_relative 'proposal_notice_inbox'
require_relative 'proposal_notice_journal'

module GameRoomTournaments
  module TournamentStartRuntime
    using GameRoomLocalization::Translations
    # Explicit application composition only. No inferred remote reader or timer.
    def configure_tournament_starts(source:,context:,clock:,registry:)
      service=TournamentStartNotice.new(source:source,context:context,clock:clock,registry:registry)
      stop_tournament_starts
      @tournament_start_service=service
      @tournament_start_registry=registry
      @tournament_start_inbox=ProposalNoticeInbox.new(service:service,metadata:TournamentStartNotice.method(:metadata),
        worker:GameRoomBackground::Work.new(runtime:app_runtime))
    end
    def stop_tournament_starts
      @tournament_start_inbox&.close
      @tournament_start_inbox=@tournament_start_service=nil
    end

    # Finite worker operation. One local durable attempt per recipient/event.
    def send_tournament_start_notices(publication_ref:)
      service=@tournament_start_service
      raise ProposalNotice::Unavailable,'Tournament starts are not connected' unless service
      account=Publication::Data.account(Session.name).downcase
      notices=service.notices(publication_ref:publication_ref)
      results={}
      notices.each do |notice|
        scope=Digest::SHA256.hexdigest(JSON.generate([account,notice['backend_identity']]))
        journal=ProposalNoticeJournal.new(program:self,path:"tournament-start-deliveries-#{scope}.json")
        results[notice['recipient']]=TournamentStartPublisher.new(service:service,sender:-> {Session.name},transaction:journal.method(:update),
          send:->(metadata,closes){send_notification(metadata['recipient'],type:TournamentStartNotice::TYPE,metadata:metadata,
            expires_in:service.remaining_seconds(closes))}).deliver(metadata:notice)
      end
      results.freeze
    end

    def tournament_start_presentation(notification)
      cached=@tournament_start_inbox&.verified(notification.id)
      notice=TournamentStartNotice.metadata(notification.metadata.to_h)
      same_app=notification.app_uuid.to_s.downcase==server_app_uuid.to_s.downcase
      verified=same_app && cached && cached[0]['metadata']==notice && cached[1]==notification.sender.to_s.downcase
      description=@tournament_start_service&.description(metadata:notice,sender:notification.sender) if same_app
      # Old notices lack a description in metadata; retain their verified text
      # while available, even after the delivery window has elapsed.
      description ||= cached[0].slice('title','game') if verified
      valid=verified && @tournament_start_service.presentable?(cached[0])
      return notification.presentation(title:_("Tournament"),body:_("Open My tournaments to see the current status."),sound:nil).suppress_default! unless description
      body=GameRoomContent.utf8(_("The tournament %{name} (%{game}) you registered for has just started."))%
        {name:GameRoomContent.utf8(description['title']),game:GameRoomContent.utf8(@tournament_start_registry.name(description['game']))}
      presentation=notification.presentation(title:_("Tournament started"),body:body,sound:nil)
      presentation.suppress_default! unless valid
      if valid && normalized_settings['invitation_sounds'] && respond_to?(:play_sound_from_asset)
        presentation.extend(GameRoomUI::NotificationSound)
        presentation.game_room_notice_player=-> {
          volume=GameRoomPreferences.sound_volume(normalized_settings,'notice')
          play_sound_from_asset('notice',volume:volume) if volume>0
        }
      end
      presentation
    rescue Publication::Invalid,ProposalNotice::Stale
      notification.presentation(title:_("Tournament"),body:_("This tournament notification is no longer available."),sound:nil).suppress_default!
    end

    def receive_tournament_start(notification)
      return unless @tournament_start_inbox && notification.app_uuid.to_s.downcase==server_app_uuid.to_s.downcase
      return if notification.respond_to?(:revoked) && notification.revoked
      @tournament_start_inbox.receive(id:notification.id,metadata:notification.metadata.to_h,sender:notification.sender)
    rescue Publication::Invalid
      false
    end
    def tournament_starts_tick
      return unless @tournament_start_inbox
      @tournament_start_inbox.tick.each do |id,_proof|
        row=EltenAPI::NotificationService.active_notifications.find{|value|value.id.to_i==id && value.cat.to_s=='app' && value.app_uuid.to_s.downcase==server_app_uuid.to_s.downcase}
        next unless row && row.revoked!=true
        notification=Programs.app_notification_from(row)
        next unless notification.type==TournamentStartNotice::TYPE
        present_deferred_contact_notification(notification)
      end
      revoked=@tournament_start_inbox.take_revoked
      EltenAPI::NotificationService.revoke_active_notifications(revoked) unless revoked.empty?
    rescue StandardError => error
      Log.warning("Tournament start delivery failed: #{error.class}: #{error.message}") if defined?(Log)
    end
  end
end
