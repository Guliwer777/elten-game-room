# encoding: UTF-8
require 'date'
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomTournaments
  # Natywne listy części terminu; bez sekund, stref i własnej pętli wejścia.
  class WindowFields
    using GameRoomLocalization::Translations
    attr_reader :fields

    def initialize(date:, time:, notice:, start: true)
      @notice = notice
      values = (date ? date.split('-').map(&:to_i) : [Time.now.year, nil, nil]) +
        (time ? time.split(':').map(&:to_i) : [nil, 0])
      labels = if start
        [_("Start: year"), _("Start: month"), _("Start: day"), _("Start: hour"), _("Start: minute")]
      else
        [_("End: year"), _("End: month"), _("End: day"), _("End: hour"), _("End: minute")]
      end
      @choices = [(1..9999).to_a, (1..12).to_a, (1..31).to_a, (0..23).to_a, (0..59).to_a].map { |items| [nil] + items }
      @fields = labels.each_with_index.map do |label, part|
        ListBox.new(@choices[part].map { |value| text(value.nil? ? _("To be decided") : format(part.zero? ? '%04d' : '%02d', value)) },
          header: text(label), index: @choices[part].index(values[part]) || 0, quiet: true)
      end
      refresh_days
      @fields.take(2).each { |field| field.on(:move) { refresh_days } }
    end

    def bind(form, date_visible: -> { true })
      @fields.each do |field|
        { key_left: -1, key_right: 1 }.each do |key, direction|
          field.on(key) do |modifiers|
            next if modifiers.any? || raw_key_held?(:key_insert)
            visible = date_visible.call ? @fields : @fields.drop(3)
            part = visible.index(field)
            next unless part
            target = part + direction
            next unless target.between?(0, visible.length - 1)
            form.index = form.fields.index(visible[target])
            form.focus
          end
        end
      end
    end

    def date=(value)
      values = value.empty? ? [Time.now.year, nil, nil] : value.split('-').map(&:to_i)
      @fields[2].index = 0
      @fields.take(2).each_with_index { |field, part| field.index = @choices[part].index(values[part]) || 0 }
      refresh_days
      @fields[2].index = @choices[2].index(values[2]) || 0
    end

    def date
      values = selected.take(3)
      values.include?(nil) ? '' : format('%04d-%02d-%02d', *values)
    end

    def time
      values = selected.last(2)
      values.include?(nil) ? '' : format('%02d:%02d', *values)
    end

    private

    def refresh_days
      year, month, day = selected.take(3)
      # Rok 2000 pozwala rozważyć 29 lutego, gdy użytkownik nie wybrał roku.
      maximum = month ? Date.new(year || 2000, month, -1, Date::GREGORIAN).day : 31
      choices = [nil] + (1..maximum).to_a
      return if @choices[2] == choices
      @choices[2] = choices
      @fields[2].options = choices.map { |value| text(value.nil? ? _("To be decided") : format('%02d', value)) }
      @fields[2].index = choices.index(day) || 0
      if day && !choices.include?(day)
        @notice.call(format(text(_("%{field}: the selected day is not available in this month. Choose the day again.")), field: @fields[2].header))
      end
    end

    def selected
      @fields.each_with_index.map { |field, part| @choices[part][field.index] }
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
