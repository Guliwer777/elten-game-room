# encoding: UTF-8
require_relative 'draft_editor'
require_relative 'local_registration_time'
require_relative 'publication'
require_relative 'tournament_datetime_field'
require_relative 'playing_days'

module GameRoomTournaments
  # Game selection, game options, then tournament rules; no write before publish.
  class TournamentSetupEditor < DraftEditor
    using GameRoomLocalization::Translations
    def initialize(program:, registry:, configure:, publish:, alert:, clock: -> { Time.now.to_i }, publication: nil, publish_label: nil)
      @publish_label = publish_label
      @clock, @publish_callback = clock, publish
      @initial_publication = publication
      if publication
        settings = JSON.parse(publication['settings_json'])
        draft = settings.merge('name'=>publication['title'], 'game_id'=>publication['game'], 'windows'=>JSON.parse(publication['schedule_json'])['windows'])
      end
      super(program: program, registry: registry, configure: configure, save: method(:publish_configuration), alert: alert, draft: draft)
    end

    def wait
      unless @initial_publication
        ids=@registry.ids
        games=ListBox.new(ids.map{|id|text(@registry.name(id))},header:text(_("Game")),quiet:true)
        cancel=Button.new(text(_("Cancel")))
        selection=GameRoomUI::Form.new([games,cancel],program:@program,quiet:true)
        selection.cancel_button=cancel
        selection.hide(cancel)
        choosing=false
        games.on(:select) do
          next if choosing
          choosing=true
          begin
            game=@registry.build(ids.fetch(games.index))
            options=@configure.call(game,copy(game.default_options))
            if options
              @setup_game_id=game.id
              @prepared_options=copy(options)
              selection.resume
            end
          ensure
            choosing=false
          end
        end
        cancel.on(:press){selection.resume}
        selection.wait
        return nil unless @setup_game_id
      end
      super
    end
    private
    def initialize_game_options
      @options_by_game[@setup_game_id]=copy(@prepared_options) if @prepared_options
    end
    def initialize_form_state; update_match_sizes; update_playing_fields; end
    def save_label; @initial_publication ? _("Save tournament changes") : (@publish_label || _("Publish in local test")); end
    def format_values; ['round_robin','groups_knockout']; end
    def format_labels; [_("Round robin"),_("Groups and knockout")]; end
    def rematch_values; [false,true]; end
    def rematch_labels; [_("No"),_("Yes")]; end
    def selected_game; @registry.build(@setup_game_id || @initial_publication.fetch('game')); end
    def update_group_fields
      super
      [@advancement, @group_count, @group_places].each { |field| @form.hide(field) }
      [@knockout_rematch, @final_rematch].compact.each do |field|
        groups_selected? ? @form.show(field) : @form.hide(field)
      end
      [[@knockout_rematch,@knockout_target],[@final_rematch,@final_target]].each do |mode,target|
        next unless target
        groups_selected? && mode.index==2 ? @form.show(target) : @form.hide(target)
      end
    end
    def setup_fields(fields)
      @games.options=@ids.map{|id|text(@registry.name(id))}
      @games.index=@draft ? (@ids.index(@draft['game_id']) || 0) : 0
      now = Time.at(@clock.call).getlocal
      settings = @initial_publication ? JSON.parse(@initial_publication['settings_json']) : {}
      modes=[text(_("No")),text(_("Yes")),text(_("Play until a specified number of wins"))]
      @knockout_rematch = ListBox.new(modes, header: text(_("Return matches in knockout rounds")), index: settings['knockout_wins_to'] ? 2 : settings['knockout_rematch'] ? 1 : 0, quiet: true)
      @final_rematch = ListBox.new(modes.dup, header: text(_("Return match in the final")), index: settings['final_wins_to'] ? 2 : settings['final_rematch'] ? 1 : 0, quiet: true)
      @knockout_target=EditBox.new(text(_("Wins required in knockout rounds")),text:(settings['knockout_wins_to'] || 2).to_s,quiet:true)
      @final_target=EditBox.new(text(_("Wins required in the final")),text:(settings['final_wins_to'] || 2).to_s,quiet:true)
      [@knockout_rematch,@final_rematch].each{|mode|mode.on(:move){interaction{update_group_fields}}}
      @count = EditBox.new(text(_("Participant limit (maximum 128)")), text: '128', quiet: true)
      @seat_counts = (2..8).to_a
      @seats = ListBox.new(@seat_counts.map(&:to_s), header: text(_("Players per match")), index: 0, quiet: true)
      @pairing = ListBox.new([text(_("All possible compositions")), text(_("Rotating compositions; equal appearances"))],
        header: text(_("Multiplayer pairings")), index: 0, quiet: true)
      @registration_open = time_fields(now, _("Registration opens"))
      @registration_close = time_fields(now + 3600, _("Registration closes"))
      @playing_start = time_fields(now + 3600, _("Tournament starts"))
      @playing_end = time_fields(now + 10800, _("Tournament ends"))
      if @initial_publication
        settings = JSON.parse(@initial_publication['settings_json'])
        @count.set_text((settings['participant_limit'] || 16).to_s)
        @seats.index = @seat_counts.index(settings['players_per_match']) || 0
        @pairing.index = %w[all_combinations balanced_cycle].index(settings['pairing']) || 0
        @registration_open = time_fields(Time.at(@initial_publication['registration_opens_at']).getlocal, _("Registration opens"))
        @registration_close = time_fields(Time.at(@initial_publication['registration_closes_at']).getlocal, _("Registration closes"))
        windows = JSON.parse(@initial_publication['schedule_json'])['windows']
        first, last = windows.first, windows.last
        @playing_start = time_fields(Time.at(LocalRegistrationTime.convert_in_zone(first['date'], first['start'], timezone: @initial_publication['timezone'])).getlocal, _("Tournament starts"))
        @playing_end = time_fields(Time.at(LocalRegistrationTime.convert_in_zone(last['end_date'] || last['date'], last['end'], timezone: @initial_publication['timezone'])).getlocal, _("Tournament ends"))
      end
      intervals=@initial_publication ? PlayingDays.local_intervals(windows,timezone:@initial_publication['timezone']) : [[now+3600,now+10800]]
      first,last=intervals.first.first,intervals.last.last
      if !@initial_publication && first.strftime('%Y-%m-%d')!=last.strftime('%Y-%m-%d')
        next_date=Date.new(first.year,first.month,first.day)+1
        first=Time.local(next_date.year,next_date.month,next_date.day,18)
        last=Time.local(next_date.year,next_date.month,next_date.day,20)
      end
      @playing_modes=%w[single daily]
      labels=[text(_("One day")),text(_("Several days"))]
      initial_mode=@initial_publication ? PlayingDays.mode(intervals) : 'single'
      if initial_mode=='preserve'
        @playing_modes << 'preserve'
        labels << text(_("Keep existing playing windows"))
      end
      @playing_mode=ListBox.new(labels,header:text(_("Tournament duration")),index:@playing_modes.index(initial_mode),quiet:true)
      @playing_date=TournamentDateTimeField.new(time:first,label:text(_("Tournament date")),parts: :date)
      @playing_last_date=TournamentDateTimeField.new(time:last,label:text(_("Last tournament day")),parts: :date)
      @playing_start=TournamentDateTimeField.new(time:first,label:text(_("Daily play starts")),parts: :time)
      @playing_end=TournamentDateTimeField.new(time:last,label:text(_("Daily play ends")),parts: :time)
      @playing_mode.on(:move){interaction{update_playing_fields}}
      @games.on(:move) do
        interaction do
          update_match_sizes
        end
      end
      @seats.on(:move) { interaction { update_pairing_field } }
      # Keep the whole tournament configuration on the Tab path; the old
      # participants/window dialog is intentionally absent from this form.
      [@name, @format, @rematch, @knockout_rematch, @knockout_target, @final_rematch, @final_target, @count, @seats, @pairing,
        @playing_mode,*@playing_date.fields,*@playing_last_date.fields,*@playing_start.fields,*@playing_end.fields,
        *@registration_open.fields, *@registration_close.fields,
        @advancement, @group_count, @group_places, fields[-2], fields[-1]]
    end
    def time_fields(time, label)
      TournamentDateTimeField.new(time:time,label:text(label))
    end
    def update_playing_fields
      mode=@playing_modes[@playing_mode.index]
      @playing_date.label=text(mode=='single' ? _("Tournament date") : _("First tournament day"))
      [@playing_date,@playing_start,@playing_end].each{|part|part.fields.each{|field|mode=='preserve' ? @form.hide(field) : @form.show(field)}}
      @playing_last_date.fields.each{|field|mode=='daily' ? @form.show(field) : @form.hide(field)}
    end
    def configure_settings
      super
      update_match_sizes
    end
    def update_match_sizes
      game = selected_game
      return unless game
      previous = @seat_counts[@seats.index]
      @seat_counts = game.tournament_capabilities(options: options_for(game)).fetch(:player_counts).select { |n| n.between?(2, 8) }
      @seats.options = @seat_counts.map(&:to_s)
      @seats.index = @seat_counts.index(previous) || 0
      @seat_counts.size == 1 ? @form.hide(@seats) : @form.show(@seats)
      update_pairing_field
    end
    def update_pairing_field
      count = @seat_counts[@seats.index]
      count && count > 2 ? @form.show(@pairing) : @form.hide(@pairing)
    end
    def publish_configuration(attributes)
      if @submitted
        @alert.call(text(_("Publication not confirmed. Check Operations before trying again.")))
        return nil
      end
      raw = text(@count.text).strip
      raise Publication::Invalid, :invalid_participant_limit unless raw.match?(/\A[0-9]{1,3}\z/) && raw.to_i.between?(2, 128)
      opens = LocalRegistrationTime.convert(@registration_open.date, @registration_open.time)
      closes = LocalRegistrationTime.convert(@registration_close.date, @registration_close.time)
      mode=@playing_modes[@playing_mode.index]
      windows=if mode=='preserve'
        PlayingDays.local_intervals(JSON.parse(@initial_publication['schedule_json'])['windows'],timezone:@initial_publication['timezone']).map{|first,last|LocalRegistrationTime.utc_window(first.to_i,last.to_i)}
      else
        PlayingDays.build(mode:mode,first_date:@playing_date.date,last_date:@playing_last_date.date,opens:@playing_start.time,closes:@playing_end.time)
      end
      start=LocalRegistrationTime.convert_utc(windows.first['date'],windows.first['start'])
      ending=LocalRegistrationTime.convert_utc(windows.last['end_date'],windows.last['end'])
      raise Publication::Invalid, :invalid_registration_time unless closes > opens && closes <= start && ending > start
      count = @seat_counts[@seats.index]
      raise Publication::Invalid, :unsupported_match_size unless count
      if attributes['format'] == 'groups_knockout'
        game = @registry.build(attributes['game_id'])
        team_size = game.team_size(attributes['game_options'], player_count: count)
        unless (count == 2 && team_size == 0) || (count == 4 && team_size == 2)
          @alert.call(text(_("Groups and knockout currently require two individual players or two fixed pairs per match. Choose round robin for other match sizes.")))
          return nil
        end
      end
      draft = attributes.merge('players_per_match' => count,
        'pairing' => %w[all_combinations balanced_cycle].fetch(@pairing.index),
        'participant_limit' => raw.to_i, 'windows' => windows)
      if draft['format'] == 'groups_knockout'
        draft.merge!('group_advancement' => GroupAdvancement::COMPACT, 'group_count' => nil, 'places_per_group' => nil)
        draft.merge!('knockout_rematch' => @knockout_rematch.index == 1, 'final_rematch' => @final_rematch.index == 1)
        [['knockout_wins_to',@knockout_rematch,@knockout_target],['final_wins_to',@final_rematch,@final_target]].each do |key,mode,field|
          next unless mode.index==2
          value=text(field.text).strip
          raise Publication::Invalid,:invalid_win_target unless value.match?(/\A[0-9]{1,2}\z/) && value.to_i.between?(1,99)
          draft[key]=value.to_i
        end
      end
      rules = @initial_publication ? @initial_publication['rules'] : text(_("Win: 2 points; draw: 1 point; loss: 0 points."))
      Publication.from_draft(draft: draft, registry: @registry, publication_key: 'setup-preflight', rules: rules,
        registration_opens_at: opens, registration_closes_at: closes, timezone: 'UTC')
      @submitted = true
      result = @publish_callback.call(draft: draft, rules: rules, registration_opens_at: opens,
        registration_closes_at: closes, timezone: 'UTC')
      unless result && result['status'] == 'confirmed'
        @alert.call(text(_("Publication not confirmed. Check Operations before trying again.")))
        return nil
      end
      enrollment = result['organizer_registration']
      if enrollment && !%w[confirmed withdrawn].include?(enrollment['status'])
        @alert.call(text(_("Tournament published, but organizer enrollment was not confirmed. Check Operations before joining again.")))
      end
      result
    rescue Publication::Invalid, LocalRegistrationTime::Invalid => error
      message=case error.code
      when :invalid_playing_hours then _("The daily end time must be later than the start time.")
      when :invalid_playing_days then _("Choose valid dates in chronological order, covering at most 256 days.")
      else _("Check tournament settings and dates: %{reason}")
      end
      @alert.call(text(message)%{reason:error.code})
      nil
    end
  end
end
