# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'proposal_notice'
require_relative 'server_participant_lease'
require_relative '../network_errors'

module GameRoomTournaments
  class ProposalNoticeDialog < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, service:, metadata:, sender:, work:)
      @program, @service, @metadata, @sender, @work = program, service, metadata, sender, work
    end

    private

    def finish(result = nil)
      @form ? super : (@finished = true)
    end

    def build_form
      @displayed = @work.call { @service.inspect(metadata: @metadata, sender: @sender) }
      return finish unless @displayed
      details = readonly(_("Game invitation"), text(_("Proposed match: %{players}")) % {players: @displayed['players'].join(' — ')})
      label=@metadata['stage']=='enter' ? _("Open match table") : @metadata['leg']==2 ? _("Return match") : _("Play")
      accept = button(label) { respond(true) }
      decline = button(_("Not now")) { respond(false) }
      back = button(_("Back"))
      make_form([details, accept, decline, back], cancel: back)
      @form.hide(accept) if @metadata['stage']!='enter' && @displayed['accepted'].include?(@metadata['recipient'])
      # Enter on details cannot consent accidentally.
      @form.accept_button = nil
    rescue ProposalNotice::Unavailable, ProposalNotice::Stale, Publication::Invalid
      alert(text(_("This match proposal changed. Refresh before responding; no new opponent was accepted.")))
      finish
    rescue StandardError => error
      recover(error)
    end

    def respond(accept)
      result = @work.call { @service.respond(metadata: @metadata, sender: @sender, displayed: @displayed, accept: accept) }
      if result.nil? || %i[pending unknown].include?(result)
        alert(text(_("Server write not confirmed. Check Operations before trying again.")))
      end
      finish(accept && %i[confirmed awaiting_consent].include?(result) ? :accepted : nil)
    rescue ProposalNotice::Unavailable, ProposalNotice::Stale, Publication::Invalid
      alert(text(_("This match proposal changed. Refresh before responding; no new opponent was accepted.")))
      finish
    rescue StandardError => error
      recover(error)
    end

    def recover(error)
      if error.is_a?(ServerParticipantLease::Busy)
        alert(text(_("Leave your current table before opening another tournament match.")))
      elsif error.is_a?(ServerPlanArchive::Unconfirmed) || error.is_a?(OperationJournal::Error) ||
          error.is_a?(IOError) || error.is_a?(SystemCallError) || GameRoomNetworkErrors.expected?(error)
        alert(text(_("Server write not confirmed. Check Operations before trying again.")))
      else
        raise error
      end
      finish
    end
  end
end
