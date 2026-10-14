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
      award=button(_("Confirm forfeit: 2 points to winner, 0 to loser, no small points")){finish(@winner.index)}
      cancel=button(_("Cancel"))
      fields=[@winner,award,cancel]
      fields.unshift(readonly(_("Cancelling the tournament match"),_("This decision ends the match in the tournament and awards 2/0 without small points. The game history remains. It does not close a table owned by another player."))) if @cancellation
      make_form(fields,cancel:cancel)
    end
  end
end
