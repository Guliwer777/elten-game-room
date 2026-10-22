require_relative 'ui_dialogs'
module GameRoomTournaments
  class TournamentInvitePicker < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:, alert:)
      @program, @workspace, @owner, @publication, @alert = program, workspace, owner, publication, alert
      @intents = {}
    end
    private
    def build_form
      return unless @owner.check && @owner.current.downcase == @publication['__insertion_user'].downcase
      users = @program.send(:run_network_task, _("Loading users")) do
        client = EltenLink::Client.new
        (EltenLink::Users.online(client) + EltenLink::Contacts.list(client)).uniq { |name| name.downcase }
      end
      snapshot = @workspace.load if users
      return unless snapshot && @owner.check
      excluded = snapshot['members'].select { |entry| entry['tournament_id'] == @publication['__id'] }.map { |entry| entry['account'] }
      excluded += snapshot.fetch('invitations', []).select { |entry| entry['tournament_id'] == @publication['__id'] }.map { |entry| entry['account'] }
      excluded << @owner.current.downcase
      @users = users.reject { |name| excluded.include?(name.downcase) }.sort_by(&:downcase)
      @list = ListBox.new(@users.map { |name| text(name) }, header: text(_("Invite to tournament")), flags: ListBox::Flags::MultiSelection, quiet: true)
      invite = button(_("Invite")) { send_selected }
      back = button(_("Back"))
      make_form([@list, invite, back], cancel: back)
      @form.accept_button = invite
      @form.hide(invite)
      @form.hide(back)
      @list.on(:select) { invite.press }
      @form.game_room_general_help_tips = [text(_("Space selects a person. Enter sends invitations to everyone selected."))]
    end
    def send_selected
      return if @submitted || !@owner.check
      selected = @list.multiselections.filter_map { |index| @users[index] }
      return @alert.call(text(_("Select at least one person."))) if selected.empty?
      @submitted = true
      results = selected.map { |name| deliver(name) }
      @alert.call(text(_("Invitations sent: %{sent}. Unconfirmed: %{unconfirmed}.")) % {sent: results.count(true), unconfirmed: results.count(false)})
      finish
    end
    def deliver(name)
      return false unless @owner.check
      @intents[name.downcase] ||= 'invite:' + SecureRandom.uuid
      receipt = @workspace.invite_to_tournament(@publication['__id'], name, @intents.fetch(name.downcase))
      return false unless receipt && receipt['status'] == 'confirmed'
      reference = {'author' => @publication['__insertion_user'].downcase, 'publication_key' => @publication['publication_key']}
      result = @program.send(:run_network_task, _("Sending invitation")) do
        @program.class.send_tournament_event(kind: 'registration', publication_ref: reference, recipient: name,
          invitation_key: receipt.fetch('values').fetch('operation_key'))
      end
      result.is_a?(Array) && !result.empty? && result.all? { |state| state == :sent }
    rescue ProposalNotice::Stale, Publication::Invalid
      false
    end
  end
end
