# encoding: UTF-8
require_relative 'draft_details'
require_relative 'window_fields'
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomTournaments
  class DraftDetailsEditor
    using GameRoomLocalization::Translations

    def initialize(program:, details:, alert:)
      @program, @alert = program, alert
      @details = JSON.parse(JSON.generate(DraftDetails::DEFAULTS.merge(details.slice(*DraftDetails::DEFAULTS.keys))))
      @window_keys = @details['windows'].each_index.to_a
      @next_window_key = @window_keys.size
    end

    def wait
      @participants = EditBox.new(text(_("Participants (one name per line; local list)")),
        type: EditBox::Flags::MultiLine, text: text(@details['participants'].join("\r\n")), max_length: 20000, quiet: true)
      @players = ListBox.new([text(_("To be decided"))] + (2..8).map { |count| text(count) }, header: text(_("Players per match")),
        index: [nil, *(2..8)].index(@details['players_per_match']) || 0, quiet: true)
      @pairing = ListBox.new([_("To be decided"), _("All possible compositions"), _("Rotating compositions; equal appearances")].map { |value| text(value) },
        header: text(_("Multiplayer pairings")), index: [nil, 'all_combinations', 'balanced_cycle'].index(@details['pairing']) || 0, quiet: true)
      @windows = ListBox.new([], header: text(_("Playing windows")), quiet: true)
      refresh_windows
      add = Button.new(text(_("Add window")))
      add.on(:press) { interaction { change_window } }
      edit = Button.new(text(_("Edit window")))
      edit.on(:press) { interaction { change_window(@windows.index) } }
      remove = Button.new(text(_("Remove window")))
      remove.on(:press) { interaction { remove_window } }
      save = Button.new(text(_("Use these settings")))
      cancel = Button.new(text(_("Cancel")))
      @form = GameRoomUI::Form.new([@participants, @players, @pairing, @windows, add, edit, remove, save, cancel], program: @program, quiet: true)
      @form.accept_button, @form.cancel_button = save, cancel
      save.on(:press) { interaction { submit } }
      cancel.on(:press) { interaction { finish } }
      @form.wait
      @result
    end

    private

    def change_window(index = nil)
      previous = index.nil? ? {} : @details['windows'][index]
      return unless previous
      previous_index = @form.index
      window = WindowEditor.new(program: @program, window: previous, windows: @details['windows'], index: index, alert: @alert).wait
      return unless window
      if index.nil?
        @details['windows'] << window
        @window_keys << @next_window_key
        @next_window_key += 1
        index = @details['windows'].size - 1
      else
        @details['windows'][index] = window
      end
      refresh_windows
      @windows.index = index
    ensure
      unless previous_index.nil?
        @form.index = previous_index if @form.index != previous_index
        @form.focus
      end
    end

    def remove_window
      @details['windows'].delete_at(@windows.index)
      @window_keys.delete_at(@windows.index)
      refresh_windows
    end

    def refresh_windows
      rows = @details['windows'].map do |window|
        "#{window['date']} #{window['start']} - #{window['end_date']} #{window['end']}"
      end
      @windows.update_options(rows, keys: @window_keys, fallback: :nearest)
    end

    def submit
      values = @details.merge('participants' => text(@participants.text).split(/\r?\n/).map(&:strip).reject(&:empty?),
        'players_per_match' => [nil, *(2..8)][@players.index], 'pairing' => [nil, 'all_combinations', 'balanced_cycle'][@pairing.index])
      DraftDetails.validate!(values)
      @result = values
      finish
    rescue DraftDetails::Invalid
      @alert.call(text(_("Check the participant names: one per line, no duplicates, at most 256 names of 1-64 characters.")))
    end

    def interaction
      return if @busy || @finished
      @busy = true
      begin
        yield
      ensure
        @busy = false
      end
    end

    def finish
      @finished = true
      @form.resume
    end

    def text(value)
      GameRoomContent.utf8(value)
    end

    class WindowEditor
      def initialize(program:, window:, windows:, index:, alert:)
        @program, @window, @alert = program, window, alert
        @windows, @index = windows, index
      end

      def wait
        notice = ->(message) { interaction { @alert.call(message) } }
        @start = WindowFields.new(date: @window['date'], time: @window['start'], notice: notice)
        @end = WindowFields.new(date: @window['end_date'], time: @window['end'], notice: notice, start: false)
        @same_day = CheckBox.new(text(_("End on the start date")), checked: @window.empty? || @window['end_date'] == @window['date'])
        save = Button.new(text(_("Use this window")))
        cancel = Button.new(text(_("Cancel")))
        @form = GameRoomUI::Form.new(@start.fields + [@same_day] + @end.fields + [save, cancel], program: @program, quiet: true)
        @start.bind(@form)
        @form.game_room_general_help_tips = [text(_("Up/Down: choose a value. Left/Right: move between parts of the start or end. Tab/Shift+Tab: move between fields. Space: toggle the end date. Enter: use this window. Escape: cancel."))]
        @end.bind(@form, date_visible: -> { !@same_day.checked })
        @separate_end_initialized = !@same_day.checked
        @same_day.on(:change) { update_end_date }
        update_end_date
        @form.accept_button, @form.cancel_button = save, cancel
        save.on(:press) { interaction { submit } }
        cancel.on(:press) { interaction { finish } }
        @form.wait
        @result
      end

      private

      def update_end_date
        if !@same_day.checked && !@separate_end_initialized
          @end.date = @start.date
          @separate_end_initialized = true
        end
        @end.fields.take(3).each { |field| @same_day.checked ? @form.hide(field) : @form.show(field) }
      end

      def submit
        visible = @start.fields + (@same_day.checked ? @end.fields.drop(3) : @end.fields)
        missing = visible.find { |field| field.index.zero? }
        if missing
          @alert.call(format(text(_("Choose a value for %{field}.")), field: missing.header))
          @form.index = @form.fields.index(missing)
          @form.focus
          return
        end
        window = { 'date' => @start.date, 'start' => @start.time,
          'end_date' => @same_day.checked ? @start.date : @end.date, 'end' => @end.time }
        candidate = @windows.dup
        @index.nil? ? candidate.push(window) : candidate[@index] = window
        DraftDetails.validate!('windows' => candidate)
        @result = window
        finish
      rescue DraftDetails::Invalid
        @alert.call(text(_("Enter valid dates and times, with the end after the start and no overlapping windows.")))
      end

      def interaction
        return if @busy || @finished
        @busy = true
        begin
          yield
        ensure
          @busy = false
        end
      end

      def finish
        @finished = true
        @form.resume
      end

      def text(value)
        GameRoomContent.utf8(value)
      end
    end
  end
end
