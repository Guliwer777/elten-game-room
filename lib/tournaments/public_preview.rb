# encoding: UTF-8
require_relative '../game_room_ui'
require_relative 'public_text'

module GameRoomTournaments
  class PublicPreview
    using GameRoomLocalization::Translations
    attr_reader :snapshot

    # Wspólna pomoc pozostaje właścicielem modalu; guard obejmuje także resume.
    class Form < GameRoomUI::Form
      attr_writer :public_interaction

      def show_game_room_help
        @public_interaction.call { super }
      end

      private

      def restore_game_room_help_focus(_field)
        # interaction odtworzy pole/ID przed jedynym Form#focus, nadal pod busy.
        nil
      end
    end
    private_constant :Form

    def initialize(program:, registry:, publication:, snapshot:, load:, join:, alert:, mode_label:, actor:, join_virtual: nil, overview: nil, withdraw: nil, manage_participants: nil, set_partner: nil, edit_tournament: nil, delete_tournament: nil,initial_action:nil)
      @initial_action=initial_action
      @program, @publication, @snapshot = program, publication, snapshot
      @load, @join, @alert = load, join, alert
      @join_virtual, @overview = join_virtual, overview
      @withdraw = withdraw
      @manage_participants = manage_participants
      @set_partner = set_partner
      @edit_tournament, @delete_tournament = edit_tournament, delete_tournament
      settings = JSON.parse(publication['settings_json'])
      @pair_game = registry.build(publication['game']).team_size(settings['game_options'], player_count: settings['players_per_match']) == 2
      @text = PublicText.new(registry: registry, mode_label: mode_label, actor: actor)
      @actor = text(actor)
      # Niezgodna para pozostaje tylko do odczytu; samo ID/tytuł nie dowodzi zamiaru.
      @stale = !@snapshot.fetch('announcements').any? { |row| row.eql?(@publication) }
    end

    def wait
      return if @running || @finished
      @running = true
      begin
        show
      ensure
        @finished = true
      end
    end

    # Context operations reuse the one-attempt guards without a details browser.
    # Only input genuinely needed by an action gets a modal.
    def perform(action)
      return if @running || @finished
      @running=true
      begin
        case action
        when :join
          @join_virtual ? virtual_join : request_join
        when :withdraw then request_withdrawal
        when :overview
          @overview.call(@publication) if @overview
          refresh_snapshot
        when :edit,:delete,:manage
          if @publication['__insertion_user'].downcase==@actor.downcase
            callback={edit:@edit_tournament,delete:@delete_tournament,manage:@manage_participants}[action]
            callback.call(@publication) if callback
            refresh_snapshot
          end
        end
      ensure
        @running=false
        @finished=true
      end
    end

    private

    def virtual_join
      @virtual_name=EditBox.new(text(_("Virtual player name (local test only)")),text:'',max_length:64,quiet:true)
      join=Button.new(text(_("Join tournament")))
      cancel=Button.new(text(_("Cancel")))
      @form=Form.new([@virtual_name,join,cancel],program:@program,quiet:true)
      @form.public_interaction=method(:interaction)
      @form.accept_button=join
      @form.cancel_button=cancel
      join.on(:press) do
        interaction do
          if text(@virtual_name.text).strip.empty?
            @alert.call(text(_("Enter a virtual player name.")))
            next
          end
          request_join
          @finished=true
          @form.resume
        end
      end
      cancel.on(:press){interaction{@finished=true;@form.resume}}
      @form.wait_without_announcement
    end

    def show
      @details = GameRoomUI::HelpText.new(text(_("Tournament details")),
        type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
        text: @text.description(@publication, @snapshot), quiet: true)
      @status = GameRoomUI::HelpText.new(text(_("Status")),
        type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: '', quiet: true)
      join = Button.new(text(_("Join tournament")))
      refresh = Button.new(text(_("Refresh")))
      back = Button.new(text(_("Back")))
      @virtual_name = EditBox.new(text(_("Virtual player name (local test only)")), text: '', max_length: 64, quiet: true) if @join_virtual
      matches = Button.new(text(_("Matches, groups and standings"))) if @overview
      leave = Button.new(text(_("Leave tournament"))) if @withdraw
      manage = Button.new(text(_("Manage participants"))) if @manage_participants && @publication['__insertion_user'].downcase == @actor.downcase
      if @publication['__insertion_user'].downcase == @actor.downcase
        edit = Button.new(text(_("Edit tournament"))) if @edit_tournament
        delete = Button.new(text(_("Delete tournament"))) if @delete_tournament
        edit.on(:press) { interaction { @edit_tournament.call(@publication); refresh_snapshot } } if edit
        delete.on(:press) { interaction { @delete_tournament.call(@publication); refresh_snapshot } } if delete
      end
      if @pair_game && @set_partner
        @partner = ListBox.new([], header: text(_("Partner")), quiet: true)
        pair = Button.new(text(_("Save partner")))
        pair.on(:press) { interaction { request_partner } }
        refresh_partners
      end
      @form = Form.new([@details, @status, @virtual_name, @partner, join, pair, leave, matches, manage, edit, delete, refresh, back].compact, program: @program, quiet: true)
      @form.public_interaction = method(:interaction)
      @form.game_room_general_help_tips = [@text.context,
        text(_("Read the rules and dates first. Tab to Join tournament, then press Enter or Space to request registration. Escape returns without joining."))]
      # Celowo bez accept_button: drugi Enter na szczegółach nie zapisuje.
      @form.cancel_button = back
      join.on(:press) { interaction { request_join } }
      leave.on(:press) { interaction { request_withdrawal } } if leave
      manage.on(:press) { interaction { @manage_participants.call(@publication); refresh_snapshot } } if manage
      matches.on(:press) { interaction { @overview.call(@publication); refresh_snapshot } } if matches
      refresh.on(:press) { interaction { refresh_snapshot } }
      back.on(:press) { interaction { @finished = true; @form.resume } }
      interaction { render_status }
      interaction(restore:!(@initial_action==:join && @virtual_name)) do
        case @initial_action
        when :join
          @virtual_name ? @form.index=@form.fields.index(@virtual_name) : request_join
        when :withdraw then request_withdrawal
        when :overview
          @overview.call(@publication) if @overview
          refresh_snapshot
        when :edit,:delete,:manage
          if @publication['__insertion_user'].downcase==@actor.downcase
            callback={edit:@edit_tournament,delete:@delete_tournament,manage:@manage_participants}[@initial_action]
            callback.call(@publication) if callback
            refresh_snapshot
          end
        end
      end if @initial_action
      @form.wait_without_announcement
    end

    def interaction(restore:true)
      return if @busy || @finished
      @busy = true
      index = @form.index
      begin
        yield
      ensure
        unless @finished
          @form.index = index if restore && @form.index != index
          @form.focus
        end
        @busy = false
      end
    end

    def registered?
      name = @virtual_name ? text(@virtual_name.text).strip : @actor
      @text.members(@publication, @snapshot).any? { |member| member.fetch('account').downcase == name.downcase }
    end

    def request_withdrawal
      return if @stale || @withdrawal_requested
      @withdrawal_requested = true
      result = @withdraw.call(@publication.fetch('__id'))
      @result_text = text(result && result['status'] == 'confirmed' ? _("Withdrawal confirmed.") : _("Withdrawal not confirmed. Check Operations before trying again."))
      @join_requested = false if result && result['status'] == 'confirmed'
      refresh_snapshot
      @alert.call(@result_text)
    end

    def request_join
      if @virtual_name && text(@virtual_name.text).strip.empty?
        @alert.call(text(_("Enter a virtual player name.")))
        return
      end
      if @stale || registered? || @join_requested
        @alert.call(@status ? @status.text : render_status)
        return
      end
      # Nie ponawiamy z tego widoku nawet po nil/niepewności callbacku.
      @join_requested = true
      record = @virtual_name ? @join_virtual.call(@publication.fetch('__id'), text(@virtual_name.text).strip) : @join.call(@publication.fetch('__id'))
      @withdrawal_requested = false if record && record['status'] == 'confirmed'
      request_partner if @partner && @partner.index > 0 && record && record['status'] == 'confirmed'
      @result_text = result_text(record)
      render_status
      @alert.call(@result_text) if record
      refresh_snapshot
      if @virtual_name && record && record['status'] == 'confirmed'
        @virtual_name.set_text('')
        @join_requested = false
      end
    end

    def result_text(record)
      return text(_("Registration not confirmed. The request was cancelled or failed. No automatic retry.")) unless record
      case record.fetch('status')
      when 'confirmed' then text(_("Registration confirmed."))
      when 'prepared', 'attempted' then text(_("Registration not confirmed. No automatic retry."))
      when 'outside_window' then text(_("Registration outside the allowed window."))
      when 'conflict' then text(_("Conflict — registration was not sent again."))
      else
        raise ArgumentError, "Unexpected tournament join status: #{record.fetch('status').inspect}"
      end
    end

    def refresh_snapshot
      fresh = @load.call
      unless fresh
        @refresh_failed = true
        render_status
        return
      end
      @snapshot, @refresh_failed = fresh, false
      refresh_partners if @partner
      current = fresh.fetch('announcements').find { |row| row.eql?(@publication) }
      @stale = current.nil?
      if current
        @publication = current
        description = @text.description(@publication, @snapshot)
        @details.set_text(description) if @details && @details.text != description
      end
      render_status
    end

    def render_status
      lines = [@text.context]
      lines << @result_text if @result_text
      lines << text(_("Already registered.")) if registered? && !@stale
      lines << text(_("Outdated preview — the announcement is missing or conflicting. Joining is unavailable.")) if @stale
      lines << text(_("Refresh failed or was cancelled. The last readable view is retained.")) if @refresh_failed
      lines << text(_("No further registration request will be sent from this preview.")) if @join_requested
      lines << @text.diagnostics(@snapshot)
      value = lines.join("\r\n\r\n")
      @status.set_text(value) if @status && @status.text != value
      value
    end

    def refresh_partners
      @partners = @snapshot['members'].select { |person| person['tournament_id'] == @publication['__id'] }
      paired = (@snapshot['pairs'] || []).select { |row| row['tournament_id'] == @publication['__id'] }.flat_map { |row| row['accounts'] }
      @partners = @partners.reject { |person| paired.include?(person['account']) }
      @partner.update_options([text(_("Without a partner yet"))] + @partners.map { |person| person['username'] }, keys: [:without_partner] + @partners.map { |person| person['account'] })
    end

    def request_partner
      return if @stale || @pairing_uncertain
      actor = @virtual_name ? text(@virtual_name.text).strip : @actor
      return if actor.empty?
      partner = @partner.index > 0 ? @partners[@partner.index - 1]['account'] : nil
      intent = 'pair-selection:' + SecureRandom.uuid
      @pairing_uncertain = true
      result = @set_partner.call(@publication['__id'], actor, partner, intent)
      @pairing_uncertain = false if result && result['status'] == 'confirmed'
      @alert.call(text(result && result['status'] == 'confirmed' ? _("Pair saved. Refresh to check the current partners.") : _("Pair not confirmed. Check Operations before trying again.")))
      refresh_snapshot
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
