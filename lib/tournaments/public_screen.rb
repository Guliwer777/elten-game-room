# encoding: UTF-8
require_relative 'public_preview'

module GameRoomTournaments
  # Callbacki należą do kontrolera, który wykonuje prawdziwe I/O w Tasks.
  class PublicScreen
    using GameRoomLocalization::Translations

    # Powrót pola/ID i focus pozostają we wspólnym guardzie tego ekranu.
    class Form < GameRoomUI::Form
      attr_writer :public_interaction
      attr_writer :lifecycle_dispatch
      def schedule_lifecycle(seconds,&block);register_timer(seconds,repeat:false,&block);end
      def update
        super
        @lifecycle_dispatch&.call
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

    def initialize(program:, registry:, load:, join:, alert:, mode_label:, actor:, join_virtual: nil, overview: nil, withdraw: nil, manage_participants: nil, set_partner: nil, edit_tournament: nil, delete_tournament: nil, create: nil, recover: nil, mine: false, results:nil,phase:nil,invite:nil,reference:nil,initial_action:nil,clock: -> { Time.now.to_i })
      @program, @registry, @load, @join, @alert = program, registry, load, join, alert
      @mode_label, @actor = mode_label, actor
      @join_virtual, @overview = join_virtual, overview
      @withdraw = withdraw
      @manage_participants = manage_participants
      @set_partner = set_partner
      @edit_tournament, @delete_tournament = edit_tournament, delete_tournament
      @create, @recover, @mine = create, recover, mine
      @results,@phase=results,phase
      @invite,@reference,@initial_action=invite,reference,initial_action
      @clock = clock
      @text = PublicText.new(registry: registry, mode_label: mode_label, actor: actor)
    end

    def run
      return if @running || @finished
      @running = true
      begin
        show
      ensure
        @finished = true
        @lifecycle_timer&.close
      end
    end

    private

    def show
      @snapshot = @load.call
      return unless @snapshot
      @lists=[ListBox.new([],header:text(_("Tournaments")),quiet:true,
        empty_label:text(_("No tournaments in this view.")))]
      @filter=ListBox.new([_("Current"),_("Completed")].map{|label|text(label)},
        header:text(_("Show tournaments")),index:0,flags:ListBox::Flags::AnyDir,quiet:true)
      @current_list=@lists.first
      @rows_by_list={}.compare_by_identity
      @status = GameRoomUI::HelpText.new(text(_("Status")),
        type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: '', quiet: true)
      view = Button.new(text(_("Open tournament")))
      refresh = Button.new(text(_("Refresh")))
      back = Button.new(text(_("Back")))
      @form = Form.new([*@lists,@filter,@status,view,refresh,back],program:@program,index:0,quiet:true)
      @form.game_room_invitation_context_field = @current_list
      @form.hide(view)
      @form.hide(back)
      @filter.on(:move){interaction(focus:false){@mine=false;render}}
      @lists.each do |list|
        list.on(:focus){@current_list=list unless (@rows_by_list[list] || []).empty?}
        list.bind_context{|menu|context_actions(menu,list)}
      end
      @form.public_interaction = method(:interaction)
      @view_refresh=ViewRefresh.new(@program){interaction(focus:false){refresh_rows}}
      @form.lifecycle_dispatch=-> do
        @view_refresh.tick unless @busy || @finished
        if @lifecycle_dirty && !@busy && !@finished
          @lifecycle_dirty=false
          interaction(focus:false) do
            expired=@snapshot['announcements'].any?{|row|row['expires_at'] && row['expires_at']<=@clock.call}
            expired ? refresh_rows : render
          end
        end
      end
      @form.accept_button, @form.cancel_button = view, back
      @form.game_room_general_help_tips = [
        text(_("Enter opens the selected tournament. Tab moves to the view filter. Ctrl+N creates a tournament; Ctrl+R refreshes the list."))]
      view.on(:press) { interaction { preview } }
      refresh.on(:press) { interaction { refresh_rows } }
      back.on(:press) { interaction { @finished = true; @form.resume } }
      interaction { render }
      if @reference
        row=@snapshot['announcements'].find{|item|item['__insertion_user'].downcase==@reference['author'] && item['publication_key']==@reference['publication_key']}
        if row
          interaction{preview(row:row,initial_action:@initial_action)}
        else
          @alert.call(text(_("This tournament is no longer available.")))
        end
        return
      end
      if @mine && @rows_by_list[@current_list].empty?
        @alert.call(text(_("You have no active tournaments. The current tournaments are shown instead.")))
        @filter.index=0
        @mine=false
        interaction{render}
      end
      if @mine && @rows_by_list[@current_list].size==1
        interaction{preview}
        return
      end
      @form.wait_without_announcement
    end

    def interaction(focus:true)
      return if @busy || @finished
      @busy = true
      index = @form.index
      selected=@lists.to_h{|list|[list,@rows_by_list[list]&.[](list.index)&.fetch('__id')]}
      begin
        yield
      ensure
        unless @finished
          selected.each do |list,id|
            position=@rows_by_list[list]&.index{|row|row['__id']==id}
            list.index=position if position
          end
          @form.index = index if @form.index != index
          @form.focus if focus
        end
        @busy = false
      end
    end

    def preview(row:nil,initial_action:nil)
      list=@lists.include?(@form.fields[@form.index]) ? @form.fields[@form.index] : @current_list
      row ||= @rows_by_list[list]&.[](list.index)
      return unless row
      dialog = PublicPreview.new(program: @program, registry: @registry, publication: row,
        snapshot: @snapshot, load: @load, join: @join, alert: @alert, mode_label: @mode_label, actor: @actor,
        join_virtual: @join_virtual, overview: @overview, withdraw: @withdraw, manage_participants: @manage_participants, set_partner: @set_partner, edit_tournament: @edit_tournament, delete_tournament: @delete_tournament,initial_action:initial_action,
        results:@results,phase:@phase,invite:@invite,clock:@clock)
      initial_action ? dialog.perform(initial_action) : dialog.wait
      unless dialog.snapshot.equal?(@snapshot)
        @snapshot = dialog.snapshot
        render
      end
    end

    def refresh_rows
      @view_refresh&.acknowledge
      refreshed = @load.call
      return unless refreshed
      @snapshot = refreshed
      render
    end

    def render
      now = @clock.call
      states = @snapshot.fetch('announcements').to_h { |row| [row['__id'], TournamentLifecycle.classify(row, now: now)] }
      rows=@snapshot.fetch('announcements').select do |row|
        completed=states.fetch(row['__id'])[:state]==:completed
        mine=row['__insertion_user'].downcase==@actor.downcase ||
          @text.members(row,@snapshot).any?{|person|person['account'].downcase==@actor.downcase}
        @filter.index==1 ? completed : !completed && (!@mine || mine)
      end
      if @filter.index==0
        groups=[[],[],[]]
        rows.each do |row|
          joined=row['__insertion_user'].downcase==@actor.downcase ||
            @text.members(row,@snapshot).any?{|person|person['account'].downcase==@actor.downcase}
          priority=joined ? 0 : (@text.can_join?(row,@snapshot,now:now) ? 1 : 2)
          groups[priority] << row
        end
        rows=groups.flatten(1)
      elsif @filter.index==1
        rows.sort_by!{|row|[-(TournamentLifecycle.ending_at(row) || row['__insertion_time']),-row['__id']]}
      end
      @rows_by_list[@current_list]=rows
      @current_list.empty_label=text(@filter.index==1 ? _("No completed tournaments.") : _("No current tournaments."))
      @current_list.update_options(rows.map do |row|
        state=states.fetch(row['__id'])
        @text.row_label(row,@snapshot)+'; '+@text.lifecycle_label(state[:state],overdue:state[:overdue])
      end,keys:rows.map{|row|row['__id']})
      reports=@snapshot.fetch('diagnostics')
      value=reports.values.any?{|items|!items.empty?} ? text(_("Some tournament information could not be read. Refresh before making changes.")) : ''
      @status.set_text(value) if @status.text != value
      value.empty? ? @form.hide(@status) : @form.show(@status)
      @lifecycle_timer&.close
      deadline=@snapshot['announcements'].filter_map{|row|TournamentLifecycle.next_change(row,now:now)}.min
      @lifecycle_timer=deadline && @form.schedule_lifecycle(deadline-now){@lifecycle_dirty=true}
    end

    def context_actions(menu,list)
      selected_tournament_context_actions(menu,list)
      menu.option(text(_("Create tournament")),nil,"n"){interaction{@create.call;refresh_rows}} if @create
      menu.option(text(_("Refresh")),nil,"r"){interaction{refresh_rows}}
      menu.option(text(_("Check pending changes"))){interaction{@recover.call;refresh_rows}} if @recover
      @form.append_game_room_invitation(menu)
    end

    def selected_tournament_context_actions(menu,list)
      row=@rows_by_list[list]&.[](list.index)
      return unless row
      captured=Publication::Data.freeze_tree(Publication::Data.copy(row))
      state=TournamentLifecycle.classify(row,now:@clock.call)[:state]
      before_start=[:soon,:registration,:waiting].include?(state)
      registered=@text.members(row,@snapshot).any?{|person|person['account'].downcase==@actor.downcase}
      actions=[[_('Open tournament'),nil,'o']]
      actions<<[_('Join tournament'),:join,'d'] if @join && (@text.can_join?(row,@snapshot,now:@clock.call) || @join_virtual && before_start) && (!registered || @join_virtual)
      actions<<[_('Tournament matches'),:overview,'m'] if @overview
      actions<<[_('Standings'),:results,'w'] if @results
      if row['__insertion_user'].downcase==@actor.downcase
        actions<<[_('Manage tournament'),:manage,'e']
      end
      actions<<[_('Leave tournament'),:withdraw,'l'] if @withdraw && registered && before_start
      actions.each do |label,action,key|
        menu.option(text(label),nil,key) do
          interaction do
            fresh=@load.call
            next unless fresh
            @snapshot=fresh
            render
            unless fresh['announcements'].any?{|current|current==captured}
              @alert.call(text(_("Outdated preview — the announcement is missing or conflicting. Joining is unavailable.")))
              next
            end
            preview(row:captured,initial_action:action)
          end
        end
      end
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
