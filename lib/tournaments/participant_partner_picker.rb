require_relative 'ui_dialogs'
module GameRoomTournaments
  class ParticipantPartnerPicker < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:, account:, confirm:, alert:)
      @program, @workspace, @owner, @publication, @account, @confirm, @alert = program, workspace, owner, publication, account, confirm, alert
    end
    private
    def build_form
      snapshot = @workspace.load
      return unless snapshot && @owner.check && @owner.current.downcase == @publication['__insertion_user'].downcase
      members = snapshot['members'].select { |person| person['tournament_id'] == @publication['__id'] }
      return unless members.any? { |person| person['account'] == @account }
      @people = members.reject { |person| person['account'] == @account }
      names = members.to_h { |person| [person['account'], person['username']] }
      @links = snapshot.fetch('pairs', []).select { |pair| pair['tournament_id'] == @publication['__id'] }.flat_map { |pair| a, b = pair['accounts']; [[a, b], [b, a]] }.to_h
      labels = @people.map do |person|
        partner = @links[person['account']]
        partner ? text(_("%{player} — partner: %{partner}")) % {player: person['username'], partner: names.fetch(partner)} : text(person['username'])
      end
      @list = ListBox.new(labels + [text(_("Without a partner"))], header: text(_("Partner")), quiet: true)
      back = button(_("Back"))
      make_form([@list, back], cancel: back)
      @form.hide(back)
      @list.on(:select) { interaction { choose } }
    end
    def choose
      return if @submitted || !@owner.check || @list.index.to_i < 0
      partner = @people[@list.index]&.fetch('account')
      if @links[@account] || partner && @links[partner]
        return unless @confirm.call(text(_("Change this pair? Previous partners will become available."))) && @owner.check
      end
      @submitted = true
      account, target = @account, partner
      account, target = partner, account if partner && account == @owner.current.downcase
      result = @workspace.set_partner(@publication['__id'], account, target, 'organizer-pair:' + SecureRandom.uuid)
      @alert.call(text(result && result['status'] == 'confirmed' && result.dig('evidence', 'pairing_applied') != false ?
        _("Pair saved. Refresh to check the current partners.") : _("Pair not confirmed. Check Operations before trying again.")))
      finish
    end
  end
end
