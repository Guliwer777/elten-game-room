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
      def game_room_invitation_in_field_context?;fields[index].is_a?(ListBox);end
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

    def initialize(program:, registry:, load:, join:, alert:, mode_label:, actor:, join_virtual: nil, overview: nil, withdraw: nil, manage_participants: nil, set_partner: nil, edit_tournament: nil, delete_tournament: nil, clock: -> { Time.now.to_i })
      @program, @registry, @load, @join, @alert = program, registry, load, join, alert
      @mode_label, @actor = mode_label, actor
      @join_virtual, @overview = join_virtual, overview
      @withdraw = withdraw
      @manage_participants = manage_participants
      @set_partner = set_partner
      @edit_tournament, @delete_tournament = edit_tournament, delete_tournament
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
      @lists=[_("Ongoing tournaments"),_("Tournament registrations"),_("Ended tournaments")].map do |label|
        ListBox.new([],header:text(label),quiet:true,empty_label:text(_("No tournament announcements.")))
      end
      @current_list=@lists.first
      @rows_by_list={}.compare_by_identity
      @status = GameRoomUI::HelpText.new(text(_("Status")),
        type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: '', quiet: true)
      view = Button.new(text(_("View tournament")))
      refresh = Button.new(text(_("Refresh")))
      back = Button.new(text(_("Back")))
      @form = Form.new([*@lists,@status,view,refresh,back],program:@program,index:0,quiet:true)
      @lists.each do |list|
        list.on(:focus){@current_list=list unless (@rows_by_list[list] || []).empty?}
        list.bind_context{|menu|context_actions(menu,list)}
      end
      @form.public_interaction = method(:interaction)
      @form.lifecycle_dispatch=-> do
        if @lifecycle_dirty && !@busy && !@finished
          @lifecycle_dirty=false
          interaction{render}
        end
      end
      @form.accept_button, @form.cancel_button = view, back
      @form.game_room_general_help_tips = [@text.context,
        text(_("Tab: ongoing, registration and ended lists. Enter: view tournament. Context menu: join, leave and organizer actions."))]
      view.on(:press) { interaction { preview } }
      refresh.on(:press) { interaction { refresh_rows } }
      back.on(:press) { interaction { @finished = true; @form.resume } }
      interaction { render }
      @form.wait_without_announcement
    end

    def interaction
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
          @form.focus
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
        join_virtual: @join_virtual, overview: @overview, withdraw: @withdraw, manage_participants: @manage_participants, set_partner: @set_partner, edit_tournament: @edit_tournament, delete_tournament: @delete_tournament,initial_action:initial_action)
      initial_action ? dialog.perform(initial_action) : dialog.wait
      unless dialog.snapshot.equal?(@snapshot)
        @snapshot = dialog.snapshot
        render
      end
    end

    def refresh_rows
      refreshed = @load.call
      return unless refreshed
      @snapshot = refreshed
      render
    end

    def render
      now = @clock.call
      states = @snapshot.fetch('announcements').to_h { |row| [row['__id'], TournamentLifecycle.classify(row, now: now)] }
      groups=Array.new(3){[]}
      @snapshot.fetch('announcements').each do |row|
        state=states.fetch(row['__id'])[:state]
      groups[[:ended,:completed].include?(state) ? 2 : state==:registration ? 1 : 0] << row
      end
      groups[2].sort_by!{|row|[-TournamentLifecycle.ending_at(row),-row['__id']]}
      @lists.each_with_index do |list,index|
        @rows_by_list[list]=groups[index]
        list.update_options(groups[index].map{|row|@text.row_label(row,@snapshot)+'; '+@text.lifecycle_label(states.fetch(row['__id'])[:state])},keys:groups[index].map{|row|row['__id']})
      end
      value = [@text.context, @text.diagnostics(@snapshot)].join("\r\n\r\n")
      @status.set_text(value) if @status.text != value
      @lifecycle_timer&.close
      deadline=@snapshot['announcements'].filter_map{|row|TournamentLifecycle.next_change(row,now:now)}.min
      @lifecycle_timer=deadline && @form.schedule_lifecycle(deadline-now){@lifecycle_dirty=true}
    end

    def context_actions(menu,list)
      row=@rows_by_list[list]&.[](list.index)
      return unless row
      captured=Publication::Data.freeze_tree(Publication::Data.copy(row))
      state=TournamentLifecycle.classify(row,now:@clock.call)[:state]
      before_start=[:soon,:registration,:waiting].include?(state)
      registered=@text.members(row,@snapshot).any?{|person|person['account'].downcase==@actor.downcase}
      actions=[[_('View tournament'),nil]]
      actions<<[_('Join tournament'),:join] if @join && (state==:registration || @join_virtual && before_start) && (!registered || @join_virtual)
      actions<<[_('Leave tournament'),:withdraw] if @withdraw && registered && before_start
      actions<<[_('Matches, groups and standings'),:overview] if @overview
      if row['__insertion_user'].downcase==@actor.downcase && before_start
        actions<<[_('Edit tournament'),:edit] if @edit_tournament
        actions<<[_('Delete tournament'),:delete] if @delete_tournament
        actions<<[_('Manage participants'),:manage] if @manage_participants
      end
      actions.each do |label,action|
        menu.option(text(label)) do
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
      if @form.game_room_invitation_context?
        menu.option(text(_("Accept invitation")),nil,"j"){@form.accept_game_room_invitation}
      end
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
