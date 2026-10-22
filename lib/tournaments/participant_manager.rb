require_relative 'ui_dialogs'
require_relative 'participant_partner_picker'
require_relative 'tournament_invitation_screen'
require_relative '../game_shortcut_bindings'
require_relative 'tournament_lifecycle'
require_relative 'view_refresh'

module GameRoomTournaments
  class ParticipantManager < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:, confirm:, alert:, invite: nil, clock: -> { GameRoomClock.now.to_i })
      @program, @workspace, @owner, @publication, @confirm, @alert, @invite, @clock = program, workspace, owner, publication, confirm, alert, invite, clock
      @attempted = {}
    end
    private
    def build_form
      return unless @owner.check
      @list = ListBox.new([], header: text(_("Participants")), quiet: true)
      back = button(_("Back"))
      make_form([@list, back], cancel: back)
      reference = {'author'=>@publication['__insertion_user'].downcase, 'publication_key'=>@publication['publication_key']}
      @view_refresh = ViewRefresh.new(@program, reference: reference) { interaction(focus: false) { refresh_members } }
      @form.hub_update = -> { @view_refresh.tick unless @busy || @finished }
      @form.hide(back)
      @list.on(:select) { interaction { open_user } }
      @list.bind_context { |menu| context(menu) }
      shortcuts = [
        ['i', [:control], :invite, _("Invite to tournament")],
        ['p', [:control], :partner, _("Choose or change partner")],
        ['l', [:control], :invitations, _("Invited users")],
        ['delete', [], :remove, _("Remove selected participant")],
        ['r', [:control], :refresh, _("Refresh")]
      ].map { |key, modifiers, action, label| GameRoomGames::GameShortcut.new(key: key, modifiers: modifiers, kind: :action, action_kind: 'tournament', action_name: action.to_s, label: text(label)) }
      GameRoomShortcutBindings.bind(@form, [@list], shortcuts, consume: ->(_) { EltenAPI::KeyboardState.clear_current_frame if defined?(EltenAPI::KeyboardState) }) do |shortcut|
        interaction { execute(shortcut.action_name.to_sym) }
      end
      refresh_members
    end
    def organizer?
      @owner.current&.downcase == @publication['__insertion_user'].downcase
    end
    def editable?
      !@stale && organizer? && [:soon, :registration, :waiting].include?(TournamentLifecycle.classify(@publication, now: @clock.call)[:state])
    end
    def pair_game?
      settings = JSON.parse(@publication['settings_json'])
      @workspace.registry.build(@publication['game']).team_size(settings['game_options'], player_count: settings['players_per_match']) == 2
    end
    def selected
      @members&.[](@list.index) if @list.index && @list.index >= 0
    end
    def open_user
      person = selected
      @program.send(:usermenu, person['username']) if person && @owner.check
    end
    def context(menu)
      available_actions.each do |action, label, key|
        account = selected&.fetch('account')
        menu.option(text(label), nil, key) { interaction { execute(action, account: account) } }
      end
    end
    def available_actions
      actions = []
      if editable?
        actions << [:invite, _("Invite to tournament"), 'i'] if @invite && TournamentTiming.registration_open?(@publication, @clock.call)
        actions << [:partner, _("Choose or change partner"), 'p'] if selected && pair_game?
        actions << [:remove, _("Remove selected participant"), :Delete] if selected
      end
      actions << [:invitations, _("Invited users"), 'l'] if organizer? && !@stale
      actions << [:refresh, _("Refresh"), 'r']
      actions
    end
    def execute(action, account: selected&.fetch('account'))
      return unless @owner.check
      return if [:remove, :partner].include?(action) && account != selected&.fetch('account')
      return unless available_actions.any? { |item| item.first == action }
      case action
      when :refresh then refresh_members
      when :invite then @invite.call(@publication); refresh_members
      when :invitations
        TournamentInvitationScreen.new(program: @program, workspace: @workspace, owner: @owner, publication: @publication, clock: @clock).run
      when :partner
        ParticipantPartnerPicker.new(program: @program, workspace: @workspace, owner: @owner,
          publication: @publication, account: account, confirm: @confirm, alert: @alert).run
        refresh_members
      when :remove then remove_selected(account)
      end
    end
    def refresh_members
      return unless @owner.check
      @view_refresh&.acknowledge
      snapshot = @workspace.load
      return unless snapshot && @owner.check
      current = snapshot['announcements'].find { |row| row['__id'] == @publication['__id'] && row['publication_key'] == @publication['publication_key'] && row['__insertion_user'] == @publication['__insertion_user'] }
      @stale = current.nil?
      @publication = current if current
      @members = snapshot['members'].select { |person| person['tournament_id'] == @publication['__id'] }
      names = @members.to_h { |person| [person['account'], person['username']] }
      links = snapshot.fetch('pairs', []).select { |pair| pair['tournament_id'] == @publication['__id'] }.flat_map { |pair| a, b = pair['accounts']; [[a, b], [b, a]] }.to_h
      labels = @members.map do |person|
        partner = links[person['account']]
        partner ? text(_("%{player} — partner: %{partner}")) % {player: person['username'], partner: names.fetch(partner)} : text(person['username'])
      end
      @list.update_options(labels, keys: @members.map { |person| person['account'] })
      @list.extend(GameRoomContextHelp::DynamicTips) unless @list.is_a?(GameRoomContextHelp::DynamicTips)
      @list.game_room_context_help_provider = -> { available_actions.map { |_action, label, key| GameRoomContextHelp.shortcut_tip(key.is_a?(Symbol) ? 'Delete' : "Ctrl+#{key.upcase}", label) } }
      @list.game_room_game_help_tips = []
    end
    def remove_selected(account)
      person = selected
      return unless person && person['account'] == account
      return @alert.call(text(_("Check Operations before trying again."))) if @attempted[account]
      return unless @confirm.call(text(_("Remove participant %{player}?")) % {player: person['username']})
      refresh_members
      return unless editable? && @members.any? { |entry| entry['account'] == account }
      @attempted[account] = true
      result = @workspace.remove_participant(@publication['__id'], account)
      @alert.call(text(result && result['status'] == 'confirmed' ? _("Participant removal confirmed.") : _("Participant removal not confirmed. Check Operations before trying again.")))
      refresh_members
    end
  end
end
