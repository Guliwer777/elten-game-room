# encoding: UTF-8
require_relative 'ui_dialogs'
module GameRoomTournaments
  class ServerForfeitScreen < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, names:, cancellation:false)
      @program,@names,@cancellation=program,names,cancellation
    end
    private
    def build_form
      @winner=ListBox.new(@names,header:text(_("Winner by forfeit")),quiet:true)
      award=button(_("Confirm forfeit")){finish(@winner.index)}
      cancel=button(_("Cancel"))
      fields=[@winner,award,cancel]
      fields.unshift(readonly(_("Cancelling the tournament match"),_("This decision ends the match in the tournament. The selected winner beats all other participants, who share last place. No game scores are added. It does not close a table owned by another player."))) if @cancellation
      make_form(fields,cancel:cancel)
    end
  end
end
