# encoding: UTF-8
# Uzupełnienie wyłącznie granicy kontrolki; natywne formularze/listy pozostają prawdziwe.
if !defined?(CheckBox) && defined?(FakeControl)
  class CheckBox < FakeControl
    attr_accessor :checked, :label
    def initialize(label, checked: false)
      super()
      @label, @checked = label, checked
    end
    def focus(*_arguments); end
  end
elsif !defined?(CheckBox)
  require File.join(EltenTestHost.root, 'src/ui/controls/check_box')
  Object.const_set(:CheckBox, EltenAPI::Controls.const_get(:CheckBox))
  # Natywne alert(false) checkboxa szuka urządzeń; w próbie nie ma żadnego.
  def SpeechOutput.list; []; end
end

module TournamentWindowTest
  PARTS = %w[year month day hour minute].freeze
  class UnavailableChoice < ArgumentError; end
  module_function

  def field(form, header, translate: ->(value) { value })
    form.fields.find { |control| control.respond_to?(:header) && control.header == translate.call(header) } || raise("Brak #{header}")
  end

  def same_day(form, translate: ->(value) { value })
    form.fields.find { |control| control.is_a?(CheckBox) && control.label == translate.call('End on the start date') } || raise('Brak wyboru daty końca')
  end

  def select(form, header, value, translate: ->(item) { item })
    control = field(form, header, translate: translate)
    label = value.nil? ? translate.call('To be decided') : format(header.end_with?('year') ? '%04d' : '%02d', value)
    index = control.options.index(label)
    raise UnavailableChoice, "Niedostępne #{header}=#{label}" if index.nil?
    control.index = index
    control.trigger(:move)
  end

  def date(form, prefix, value, translate: ->(item) { item })
    unless value.empty? || value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
      raise UnavailableChoice, 'Daty mają wyłącznie kanoniczny format'
    end
    values = value.empty? ? [nil, nil, nil] : value.split('-').map(&:to_i)
    PARTS.take(3).zip(values).each { |part, item| select(form, "#{prefix}: #{part}", item, translate: translate) }
  end

  def time(form, prefix, value, translate: ->(item) { item })
    unless value.empty? || value.match?(/\A[0-9]{2}:[0-9]{2}\z/)
      raise UnavailableChoice, 'Godziny mają wyłącznie kanoniczny format'
    end
    values = value.empty? ? [nil, nil] : value.split(':').map(&:to_i)
    PARTS.last(2).zip(values).each { |part, item| select(form, "#{prefix}: #{part}", item, translate: translate) }
  end

  def fill(form, date:, start:, end_date:, finish:, translate: ->(item) { item })
    self.date(form, 'Start', date, translate: translate)
    time(form, 'Start', start, translate: translate)
    checkbox = same_day(form, translate: translate)
    checkbox.checked = end_date.empty? || end_date == date
    checkbox.trigger(:change)
    self.date(form, 'End', end_date, translate: translate) unless checkbox.checked
    time(form, 'End', finish, translate: translate)
  end

  def choices(form)
    form.fields.select { |control| control.is_a?(ListBox) }.map { |control| control.options[control.index] }
  end

  def values(form)
    starts, ends = %w[Start End].map do |prefix|
      PARTS.map do |part|
        control = field(form, "#{prefix}: #{part}")
        control.index.zero? ? nil : control.options[control.index]
      end
    end
    date = starts.take(3).include?(nil) ? '' : starts.take(3).join('-')
    finish_date = same_day(form).checked ? date : (ends.take(3).include?(nil) ? '' : ends.take(3).join('-'))
    [date, starts.last(2).include?(nil) ? '' : starts.last(2).join(':'), finish_date,
      ends.last(2).include?(nil) ? '' : ends.last(2).join(':')]
  end
end
