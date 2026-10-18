# encoding: UTF-8
require_relative '../game_room_ui'
require_relative 'public_text'
require_relative 'view_refresh'

module GameRoomTournaments
  class PublicPreview
    using GameRoomLocalization::Translations
    attr_reader :snapshot

    # Wspólna pomoc pozostaje właścicielem modalu; guard obejmuje także resume.
    class Form < GameRoomUI::Form
      attr_writer :public_interaction
      attr_writer :public_update
      def update
        super
        @public_update&.call
      end

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

    def initialize(program:, registry:, publication:, snapshot:, load:, join:, alert:, mode_label:, actor:, join_virtual: nil, overview: nil, withdraw: nil, manage_participants: nil, set_partner: nil, edit_tournament: nil, delete_tournament: nil,initial_action:nil,results:nil,phase:nil,invite:nil,clock:-> {Time.now.to_i})
      @initial_action=initial_action
      @program, @publication, @snapshot = program, publication, snapshot
      @load, @join, @alert = load, join, alert
      @join_virtual, @overview = join_virtual, overview
      @withdraw = withdraw
      @manage_participants = manage_participants
      @set_partner = set_partner
      @edit_tournament, @delete_tournament = edit_tournament, delete_tournament
      @results,@phase,@clock=results,phase,clock
      @invite=invite
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
        when :results
          @results.call(@publication) if @results
          refresh_snapshot
        when :manage then manage_tournament
        when :edit,:delete
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
      @status = GameRoomUI::HelpText.new(text(_("Status")),
        type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: '', quiet: true)
      back = Button.new(text(_("Back")))
      @actions=ListBox.new([],header:text(_("Actions")),quiet:true)
      @virtual_name=EditBox.new(text(_("Virtual player name (local test only)")),text:'',max_length:64,quiet:true) if @join_virtual
      @form = Form.new([@actions,@virtual_name,@status,back].compact, program: @program, quiet: true)
      @form.hide(back)
      @form.public_interaction = method(:interaction)
      reference={'author'=>@publication['__insertion_user'].downcase,'publication_key'=>@publication['publication_key']}
      @view_refresh=ViewRefresh.new(@program,reference:reference){interaction(focus:false){refresh_snapshot}}
      @form.public_update=-> {@view_refresh.tick unless @busy || @finished}
      @form.game_room_general_help_tips = [text(_("Choose an action with the arrows and press Enter. Escape returns without leaving the tournament."))]
      @form.cancel_button = back
      @actions.on(:select){interaction{execute_action(@action_keys[@actions.index])}}
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
        when :results
          @results.call(@publication) if @results
          refresh_snapshot
        when :manage then manage_tournament
        when :edit,:delete
          if @publication['__insertion_user'].downcase==@actor.downcase
            callback={edit:@edit_tournament,delete:@delete_tournament,manage:@manage_participants}[@initial_action]
            callback.call(@publication) if callback
            refresh_snapshot
          end
        end
      end if @initial_action
      @form.wait_without_announcement
    end

    def execute_action(action)
      case action
      when :join then request_join
      when :withdraw then request_withdrawal
      when :overview then @overview.call(@publication);refresh_snapshot
      when :results then @results.call(@publication);refresh_snapshot
      when :partner then choose_partner
      when :participants
        value=@text.members(@publication,@snapshot).map{|person|person['username']}.join("\r\n")
        show_document(_("Participants"),value)
      when :rules then show_document(_("Information and rules"),@text.description(@publication,@snapshot))
      when :manage then manage_tournament
      when :refresh then refresh_snapshot
      end
    end

    def show_document(header,value)
      field=GameRoomUI::HelpText.new(text(header),type:EditBox::Flags::ReadOnly|EditBox::Flags::MultiLine,text:value,quiet:true)
      back=Button.new(text(_("Back")))
      form=GameRoomUI::Form.new([field,back],program:@program,quiet:true)
      form.hide(back)
      form.cancel_button=back
      back.on(:press){form.resume}
      form.wait
    end

    def manage_tournament
      return unless @publication['__insertion_user'].downcase==@actor.downcase
      state=TournamentLifecycle.classify(@publication,now:@clock.call)[:state]
      options=[]
      before_start=[:soon,:registration,:waiting].include?(state)
      if before_start
        options << [:invite,_("Invite to tournament")] if @invite && state==:registration && @text.can_join?(@publication,@snapshot,now:@clock.call)
        options << [:manage,_("Manage participants")] if @manage_participants
        options << [:edit,_("Edit tournament")] if @edit_tournament
        options << [:open,_("Open registration")] if @phase && state!=:registration
        options << [:close,_("Close registration")] if @phase && state==:registration
        options << [:start,_("Start tournament")] if @phase
      end
      options << [:delete,_("Cancel tournament")] if @delete_tournament && state!=:completed
      list=ListBox.new(options.map{|_,label|text(label)},header:text(_("Manage tournament")),quiet:true)
      back=Button.new(text(_("Back")))
      form=GameRoomUI::Form.new([list,back],program:@program,quiet:true)
      form.cancel_button=back
      form.hide(back)
      busy=false
      list.on(:select) do
        next if busy
        busy=true
        begin
          action=options[list.index]&.first
          if [:open,:close,:start].include?(action)
            @phase.call(@publication,action.to_s)
          elsif action
            {invite:@invite,manage:@manage_participants,edit:@edit_tournament,delete:@delete_tournament}.fetch(action).call(@publication)
          end
          form.resume
        ensure
          busy=false
        end
      end
      back.on(:press){form.resume}
      form.wait
      refresh_snapshot
    end

    def interaction(restore:true,focus:true)
      return if @busy || @finished
      @busy = true
      index = @form.index
      begin
        yield
      ensure
        unless @finished
          @form.index = index if restore && @form.index != index
          @form.focus if focus
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
      @result_text = result_text(record)
      render_status
      @alert.call(@result_text) if record
      refresh_snapshot
      if @virtual_name && record && record['status'] == 'confirmed'
        @virtual_name.set_text('')
        @join_requested = false
        render_actions
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
      @view_refresh&.acknowledge
      fresh = @load.call
      unless fresh
        @refresh_failed = true
        render_status
        return
      end
      @snapshot, @refresh_failed = fresh, false
      current = fresh.fetch('announcements').find { |row| row['__id']==@publication['__id'] && row['publication_key']==@publication['publication_key'] && row['__insertion_user']==@publication['__insertion_user'] }
      @stale = current.nil?
      if current
        @publication = current
      end
      render_status
    end

    def render_status
      lines = []
      lines << @result_text if @result_text
      lines << text(_("Outdated preview — the announcement is missing or conflicting. Joining is unavailable.")) if @stale
      lines << text(_("Refresh failed or was cancelled. The last readable view is retained.")) if @refresh_failed
      value = lines.join("\r\n\r\n")
      @status.set_text(value) if @status && @status.text != value
      if @form && @status
        value.empty? ? @form.hide(@status) : @form.show(@status)
      end
      render_actions if @actions
      value
    end

    def render_actions
      state=TournamentLifecycle.classify(@publication,now:@clock.call)[:state]
      actions=[]
      unless @stale
        actions << [:join,_("Join tournament")] if @join && !registered? && !@join_requested && @text.can_join?(@publication,@snapshot,now:@clock.call)
        actions << [:overview,_("Tournament matches")] if @overview
        actions << [:results,_("Standings")] if @results
        actions << [:participants,_("Participants")]
        actions << [:rules,_("Information and rules")]
        actions << [:partner,_("Team partner")] if registered? && @pair_game && @set_partner && [:soon,:registration,:waiting].include?(state)
        actions << [:manage,_("Manage tournament")] if @publication['__insertion_user'].downcase==@actor.downcase
        actions << [:withdraw,_("Leave tournament")] if registered? && @withdraw && [:soon,:registration,:waiting].include?(state)
      end
      actions << [:refresh,_("Refresh")]
      @actions.header=@text.action_header(@publication,@snapshot,now:@clock.call)
      @action_keys=actions.map(&:first)
      @actions.update_options(actions.map{|_,label|text(label)},keys:@action_keys)
    end

    def choose_partner
      return if @stale || @pairing_uncertain
      actor=@actor.downcase
      pairs=(@snapshot['pairs'] || []).select{|row|row['tournament_id']==@publication['__id']}
      requests=(@snapshot['pair_requests'] || []).select{|row|row['tournament_id']==@publication['__id']}
      own=pairs.find{|row|row['accounts'].include?(actor)}
      request=requests.find{|row|row['from']==actor}
      status=if own
        text(_("Your partner: %{player}"))%{player:(own['accounts']-[actor]).first}
      elsif request
        text(_("Waiting for %{player} to confirm your partnership."))%{player:request['to']}
      else
        text(_("Choose a partner. The other player must also choose you to confirm the team."))
      end
      unavailable=pairs.reject{|row|row.equal?(own)}.flat_map{|row|row['accounts']}
      people=@text.members(@publication,@snapshot).reject{|person|person['account']==actor || unavailable.include?(person['account'])}
      labels=people.map do |person|
        requests.any?{|row|row['from']==person['account'] && row['to']==actor} ? text(_("Confirm partnership with %{player}"))%{player:person['username']} : person['username']
      end
      list=ListBox.new(labels+[text(_("Without a partner"))],header:text(_("Partner")),quiet:true)
      details=GameRoomUI::HelpText.new(text(_("Team")),type:EditBox::Flags::ReadOnly|EditBox::Flags::MultiLine,text:status,quiet:true)
      back=Button.new(text(_("Back")))
      form=GameRoomUI::Form.new([details,list,back],program:@program,quiet:true)
      form.cancel_button=back
      form.hide(back)
      list.on(:select) do
        next if @pairing_uncertain
        @pairing_uncertain=true
        partner=people[list.index]&.fetch('account')
        result=@set_partner.call(@publication['__id'],actor,partner,'pair-selection:'+SecureRandom.uuid)
        @pairing_uncertain=false if result && result['status']=='confirmed'
        message = if result && result['status'] == 'confirmed'
          result.dig('evidence', 'pairing_applied') == false ?
            _("The tournament changed. Refresh its view before changing it again.") : _("Partner choice saved.")
        else
          _("The partner choice could not be confirmed. Refresh to check its status.")
        end
        @alert.call(text(message))
        form.resume
      end
      back.on(:press){form.resume}
      form.wait
      refresh_snapshot
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
