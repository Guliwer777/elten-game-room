require_relative 'ui_dialogs'
require_relative 'view_refresh'
module GameRoomTournaments
  class TournamentInvitationScreen < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:, clock:)
      @program, @workspace, @owner, @publication, @clock = program, workspace, owner, publication, clock
    end
    private
    def build_form
      return unless @owner.check && @owner.current.downcase == @publication['__insertion_user'].downcase
      @list = ListBox.new([], header: text(_("Invited users")), quiet: true)
      back = button(_("Back"))
      make_form([@list, back], cancel: back)
      reference = {'author'=>@publication['__insertion_user'].downcase, 'publication_key'=>@publication['publication_key']}
      @view_refresh = ViewRefresh.new(@program, reference: reference) { interaction(focus: false) { refresh } }
      @form.hub_update = -> { @view_refresh.tick unless @busy || @finished }
      @form.hide(back)
      @list.on(:select) { interaction { person = @entries[@list.index]; @program.send(:usermenu, person['username']) if person && @owner.check } }
      @list.bind_context { |menu| menu.option(text(_("Refresh")), nil, 'r') { interaction { refresh } } }
      refresh
    end
    def refresh
      @view_refresh&.acknowledge
      data = @workspace.load
      return unless data && @owner.check
      row = data['announcements'].find { |item| item['__id'] == @publication['__id'] && item['publication_key'] == @publication['publication_key'] }
      members = data['members'].select { |person| person['tournament_id'] == @publication['__id'] }.map { |person| person['account'] }
      @entries = data.fetch('invitations', []).select do |entry|
        row && entry['tournament_id'] == row['__id'] && !entry['resolved'] && !members.include?(entry['account']) &&
          (entry['status'] == 'declined' || TournamentTiming.registration_open?(row, @clock.call))
      end
      @list.update_options(@entries.map { |entry| text(entry['username']) + text(' — ') + text(entry['status'] == 'declined' ? _("Declined") : _("Pending")) },
        keys: @entries.map { |entry| entry['account'] })
    end
  end
end
