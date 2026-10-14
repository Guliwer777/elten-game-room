# encoding: UTF-8
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative 'window_fields'
require_relative 'publication'

module GameRoomTournaments
  # Jednorazowy formularz lokalnej publikacji. Kopię szkicu i jego rewizję dla
  # intentu przechowuje hub; ten formularz nigdy nie zapisuje szkiców/rosteru.
  class PublicationEditor
    using GameRoomLocalization::Translations
    Data = Publication::Data
    DEADLINE_HOURS = [nil, 1, 2, 3, 24].freeze

    # convert_time.call(date, time) -> Integer sekund UTC. Kompozycja huba
    # tłumaczy wyłącznie LocalRegistrationTime::Invalid na ten typ, zachowując
    # code (:invalid_time/:ambiguous_time/:unsupported_time). Inne wyjątki
    # oraz inny typ wyniku są błędami programu, nie błędami formularza.
    class InvalidTime < StandardError
      attr_reader :code
      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    # Pomoc nadal należy w całości do wspólnego Form. Lokalna otoczka obejmuje
    # guardem jedynie jej modal, resume i natywny powrót fokusu.
    class Form < GameRoomUI::Form
      attr_writer :publication_interaction

      def show_game_room_help
        @publication_interaction.call { super }
      end

      private

      # Jedyny odczyt powrotu: wspólny Form oddaje go przez istniejący hook.
      def restore_game_room_help_focus(field)
        self.index = fields.index(field)
        focus
      end
    end
    private_constant :Form

    def initialize(program:, draft:, registry:, mode_label:, actor:, timezone:, convert_time:, save:, alert:, clock: -> { Time.now.to_i })
      @registry = registry
      @program, @convert_time, @save, @alert, @clock = program, convert_time, save, alert, clock
      @draft = Data.freeze_tree(Data.copy(draft))
      @mode_label, @actor, @timezone = [mode_label, actor, timezone].map { |value| text(value).dup.freeze }
      raise ArgumentError, 'PublicationEditor requires local_test:system' unless @timezone == 'local_test:system'
    end

    def wait
      return @result if @running || @finished
      @running = true
      begin
        interaction { build_form; @form.focus }
        @form.wait_without_announcement
        @result
      ensure
        @running = false
        @finished = true
      end
    end

    private

    def build_form
      summary = readonly(text(_("Publish draft in local test")), summary_text)
      @rules = EditBox.new(text(_("Tournament rules")), type: EditBox::Flags::MultiLine, text: '', quiet: true)
      notice = ->(message) { interaction { reject(text(message), @form.fields[@form.index]) } }
      opening = readonly(text(_("Registration")), text(_("Registration opens when you publish.")))
      @deadline = ListBox.new([_("Specific date and time"), _("1 hour before the start"),
        _("2 hours before the start"), _("3 hours before the start"), _("One day (24 hours) before the start")].map { |label| text(label) },
        header: text(_("Registration deadline")), index: 0, quiet: true)
      @closing = WindowFields.new(date: nil, time: nil, notice: notice, start: false)
      label_dates
      @status = readonly(text(_("Status")), text(_("Not submitted.")))
      @publish = Button.new(text(_("Publish in local test")))
      cancel = Button.new(text(_("Cancel")))
      @form = Form.new([summary, @rules, opening, @deadline, *@closing.fields, @status, @publish, cancel], program: @program, quiet: true)
      @form.publication_interaction = method(:interaction)
      @form.cancel_button = cancel
      @closing.bind(@form)
      @deadline.on(:move) { interaction { update_deadline_fields unless @attempted } }
      tips = [summary_text, text(_("Registration opens when you publish.")),
        text(_("Choose a specific registration deadline or 1, 2, 3 or 24 hours before the start of the first playing window (the earliest start saved in the draft, not an individual match time). One day means exactly 24 hours, even across daylight saving changes.")),
        text(_("Use Up and Down to choose a value, Left and Right to move between date or time parts, and Tab to move between fields.")),
        text(_("Enter in the rules inserts a new line. Only the Publish in local test button submits. Escape cancels."))]
      @form.game_room_general_help_tips = tips
      @form.game_room_text_help_tips = tips
      @publish.on(:press) { interaction { submit } }
      cancel.on(:press) { interaction { finish } }
    end

    # Natywne hide/show nie przebudowuje formularza ani nie odczytuje fokusu.
    def update_deadline_fields
      @closing.fields.each do |field|
        @deadline.index.zero? ? @form.show(field) : @form.hide(field)
      end
    end

    def relative_deadline
      windows = @draft['windows']
      DraftDetails.validate!('windows' => windows)
      raise DraftDetails::Invalid, :invalid_windows if windows.empty?
      first = windows.min_by { |window| [window.fetch('date'), window.fetch('start')] }
      start = @convert_time.call(first.fetch('date'), first.fetch('start'))
      raise ArgumentError, 'convert_time must return UTC Integer seconds' unless Integer === start
      raise InvalidTime, :unsupported_time unless Data.integer?(start)
      start - DEADLINE_HOURS.fetch(@deadline.index) * 3600
    rescue DraftDetails::Invalid
      reject(text(_("Relative registration deadlines require valid playing windows in the draft. Correct the draft or choose a specific date and time.")), @deadline)
      nil
    rescue InvalidTime => error
      raise ArgumentError, "Unknown registration time error: #{error.code}" unless [:invalid_time, :ambiguous_time, :unsupported_time].include?(error.code)
      reject(text(_("The first playing window has a nonexistent, ambiguous or unsupported start in the computer's system time zone. Correct the draft or choose a specific date and time.")), @deadline)
      nil
    end

    def label_dates
      labels = [_("Registration closes: year"),
        _("Registration closes: month"), _("Registration closes: day"), _("Registration closes: hour"), _("Registration closes: minute")]
      @closing.fields.zip(labels) { |field, label| field.header = text(label) }
    end

    def summary_text
      [@mode_label, format(text(_("Test actor: %{actor}")), actor: @actor),
        format(text(_("Draft: %{name}; game: %{game}")), name: text(@draft.fetch('name')), game: text(@draft.fetch('game_id'))),
        @timezone, text(_("Local test: registration dates use this computer’s system time zone. Ambiguous or nonexistent times are rejected."))].join("\n")
    end

    def readonly(header, value)
      EditBox.new(header, type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: value, quiet: true)
    end

    def submit
      return if @attempted
      missing = @closing.fields.find { |field| field.index.zero? } if @deadline.index.zero?
      if missing
        reject(format(text(_("Choose a value for %{field}.")), field: missing.header), missing)
        return
      end
      rules = validated_rules
      return unless rules
      closes = @deadline.index.zero? ? converted_time(@closing) : relative_deadline
      return if closes.nil?
      return reject_deadline unless Data.integer?(closes)
      opens = @clock.call
      raise ArgumentError, 'clock must return UTC Integer seconds' unless Integer === opens
      return reject_deadline unless Data.integer?(opens) && closes > opens
      return unless preflight(rules, opens, closes)
      @attempted = true
      lock_document
      @status.set_text(unconfirmed_text)
      record = @save.call(rules: rules, registration_opens_at: opens,
        registration_closes_at: closes, timezone: @timezone)
      present_result(record)
    end

    # Czysta walidacja tej samej migawki i wybranych dat, bez workera i I/O.
    # Techniczny klucz przedpublikacyjny nie jest utrwalany ani przekazywany
    # do save i nie nadaje uprawnień. Tożsamość nadal przydziela PublicService.
    def preflight(rules, opens, closes)
      Publication.from_draft(draft: @draft, registry: @registry, publication_key: 'preflight-only-not-persisted',
        rules: rules, registration_opens_at: opens, registration_closes_at: closes, timezone: @timezone)
      true
    rescue Publication::Invalid => error
      message = case error.code
      when :missing_windows, :invalid_windows
        _("This form has not requested publication. Add or correct the playing windows in the saved draft.")
      when :incomplete_settings, :invalid_pairing
        _("This form has not requested publication. Complete the match settings in the saved draft: tournament format, pairing, rematches and players per match.")
      when :invalid_options
        _("This form has not requested publication. Correct the game options in the saved draft.")
      when :invalid_players_per_match
        _("This form has not requested publication. Correct the number of players per match in the saved draft.")
      when :invalid_group_configuration
        _("This form has not requested publication. Correct the number of groups and qualifying places in the saved draft.")
      else
        _("This form has not requested publication. The saved draft contains invalid publication data. Correct it in Local tournament drafts.")
      end
      message = text(message)
      @status.set_text(message)
      reject(message, @form.fields[@form.index])
      false
    end

    def reject_deadline
      reject(text(_("Registration must close later than the moment you publish; both UTC times must be nonnegative and within the supported range.")),
        @deadline.index.zero? ? @closing.fields.first : @deadline)
    end

    # Natywny ListBox nie ma ReadOnly. Raz, PRZED save, zastępujemy wyłącznie
    # wybieraki ich tekstowymi wartościami w tych samych pozycjach formularza.
    # Regulamin zachowuje tę samą kontrolkę, treść, kursor i zaznaczenie.
    def lock_document
      @rules.flags |= EditBox::Flags::ReadOnly
      [@deadline, *@closing.fields].each do |field|
        @form.fields[@form.fields.index(field)] = readonly(field.header, text(field.options[field.index]))
      end
    end

    def present_result(record)
      unless record.nil? || Hash === record
        raise ArgumentError, 'save must return an operation journal record or nil'
      end
      status = record && record['status']
      message = case status
      when 'confirmed'
        @result = record
        text(_("Publication confirmed in local test."))
      when 'prepared', 'attempted'
        unconfirmed_text
      when 'conflict'
        text(_("Conflict: publication was not confirmed. This form cannot send again. Check the operation in the local test hub."))
      when 'outside_window'
        text(_("The operation is outside the allowed window. This form cannot send again. Check the operation in the local test hub."))
      else
        raise ArgumentError, "Unknown publication status: #{status.inspect}" unless record.nil?
        unconfirmed_text
      end
      @status.set_text(message)
      if status == 'confirmed'
        finish
      else
        reject(message, @status)
      end
    end

    def unconfirmed_text
      text(_("Publication not confirmed. This form cannot send again. Check the operation in the local test hub."))
    end

    def converted_time(fields)
      value = @convert_time.call(fields.date, fields.time)
      raise ArgumentError, 'convert_time must return UTC Integer seconds' unless Integer === value
      value
    rescue InvalidTime => error
      message = case error.code
      when :invalid_time
        _("This registration date or time does not exist. Choose another time.")
      when :ambiguous_time
        _("This registration time is ambiguous in the computer's system time zone. Choose another time.")
      when :unsupported_time
        _("This registration time is not supported by the computer's system time zone. Choose another time.")
      else
        raise ArgumentError, "Unknown registration time error: #{error.code}"
      end
      reject(text(message), fields.fields.first)
      nil
    end

    def validated_rules
      Data.text!(@rules.text, bytes: Publication::MAX_RULES_BYTES, multiline: true).dup.freeze
    rescue Publication::Invalid
      reject(text(_("Enter nonblank tournament rules (up to 16384 UTF-8 bytes; only line breaks and tabs may be control characters).")), @rules)
      nil
    end

    def reject(message, field)
      @alert.call(message)
      @form.index = @form.fields.index(field)
      @form.focus
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
