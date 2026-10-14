# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'proposal_notice'

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
      accept = button(@metadata['leg'] == 2 ? _("Return match") : _("Play")) { respond(true) }
      decline = button(_("Not now")) { respond(false) }
      back = button(_("Back"))
      make_form([details, accept, decline, back], cancel: back)
      @form.hide(accept) if @displayed['accepted'].include?(@metadata['recipient'])
      # Enter on details cannot consent accidentally.
      @form.accept_button = nil
    rescue ProposalNotice::Unavailable, ProposalNotice::Stale, Publication::Invalid
      alert(text(_("This match proposal changed. Refresh before responding; no new opponent was accepted.")))
      finish
    end

    def respond(accept)
      result = @work.call { @service.respond(metadata: @metadata, sender: @sender, displayed: @displayed, accept: accept) }
      if result.nil? || %i[pending unknown].include?(result)
        alert(text(_("Server write not confirmed. Check Operations before trying again.")))
      end
      finish
    rescue ProposalNotice::Unavailable, ProposalNotice::Stale, Publication::Invalid
      alert(text(_("This match proposal changed. Refresh before responding; no new opponent was accepted.")))
      finish
    end
  end
end
