require_relative 'local_test_dialogs'

module GameRoomTournaments
  class LocalParticipantManager < LocalTestDialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:, confirm:, alert:)
      @program, @workspace, @owner, @publication, @confirm, @alert = program, workspace, owner, publication, confirm, alert
      @attempted = {}
    end
    private
    def build_form
      return unless @owner.check
      @list = ListBox.new([], header: text(_("Registered participants")), quiet: true)
      remove = button(_("Remove selected participant")) { remove_selected }
      refresh = button(_("Refresh")) { refresh_members }
      back = button(_("Back"))
      settings = JSON.parse(@publication['settings_json'])
      if @workspace.registry.build(@publication['game']).team_size(settings['game_options'], player_count: settings['players_per_match']) == 2
        @partner = ListBox.new([], header: text(_("Partner")), quiet: true)
        pair = button(_("Change selected participant's partner")) { change_partner }
      end
      @pairs = readonly(_("Tournament pairs"), '')
      make_form([@list, @partner, pair, @pairs, remove, refresh, back].compact, cancel: back)
      refresh_members
    end
    def refresh_members
      return unless @owner.check
      snapshot = @workspace.load
      return unless snapshot && @owner.check
      @members = snapshot['members'].select { |person| person['tournament_id'] == @publication['__id'] }
      @list.update_options(@members.map { |person| person['username'] }, keys: @members.map { |person| person['account'] })
      @partner.update_options([text(_("Without a partner yet"))] + @members.map { |person| person['username'] }, keys: [:without_partner] + @members.map { |person| person['account'] }) if @partner
      @pairs.set_text((snapshot['pairs'] || []).select { |row| row['tournament_id'] == @publication['__id'] }.map { |row| row['accounts'].join(' — ') }.join("\r\n"))
    end
    def change_partner
      return unless @owner.check && !@pairing_uncertain
      account = @members[@list.index]&.fetch('account')
      return unless account
      partner = @partner.index > 0 ? @members[@partner.index - 1]['account'] : nil
      return unless @confirm.call(text(_("Change this pair? Previous partners will become available."))) && @owner.check
      @pairing_uncertain = true
      result = @workspace.set_partner(@publication['__id'], account, partner, 'organizer-pair:' + SecureRandom.uuid)
      @pairing_uncertain = false if result && result['status'] == 'confirmed'
      message = if result && result['status'] == 'confirmed'
        result.dig('evidence', 'pairing_applied') == false ?
          _("The tournament changed. Refresh its view before changing it again.") : _("Pair saved. Refresh to check the current partners.")
      else
        _("Pair not confirmed. Check Operations before trying again.")
      end
      @alert.call(text(message))
      refresh_members
    end
    def remove_selected
      return unless @owner.check
      person = @members && @members[@list.index]
      return unless person
      account = person['account']
      if @attempted[account]
        @alert.call(text(_("Check Operations before trying again.")))
        return
      end
      return unless @confirm.call(text(_("Remove participant %{player}?")) % {player: person['username']}) && @owner.check
      @attempted[account] = true
      result = @workspace.remove_participant(@publication['__id'], account)
      @alert.call(text(result && result['status'] == 'confirmed' ? _("Participant removal confirmed.") : _("Participant removal not confirmed. Check Operations before trying again.")))
      refresh_members
    end
  end
end
