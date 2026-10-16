# encoding: UTF-8
# Wspólne dane i selektory testów; bez importu scenariuszy i bez I/O.
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)
require_relative 'assertions'
require_relative '../../games/catalog'
include GameRoomTest::Assertions

module TournamentPublicationEditorTest
  HEADER = 'Publish draft in local test'.freeze
  RULES = 'Tournament rules'.freeze
  PUBLISH = 'Publish in local test'.freeze
  ZONE = 'local_test:system'.freeze
  ZONE_NOTICE = 'Local test: registration dates use this computer’s system time zone. Ambiguous or nonexistent times are rejected.'.freeze
  module_function

  def draft
    { 'id' => 'draft-1', 'revision' => 7, 'name' => 'Zmieniony szkic — Łódź',
      'game_id' => 'chess', 'game_options' => { 'bot_delay' => 3 },
      'participants' => ['NIE WYSYŁAJ'], 'windows' => [], 'format' => 'round_robin',
      'rematch' => false, 'players_per_match' => 2, 'pairing' => 'all_combinations' }
  end

  def windows
    [{ 'date' => '2026-10-03', 'start' => '20:15', 'end_date' => '2026-10-03', 'end' => '21:00' },
      { 'date' => '2026-10-02', 'start' => '18:30', 'end_date' => '2026-10-02', 'end' => '19:00' }]
  end

  def args(**options)
    { program: Object.new, draft: draft.merge('windows' => windows), registry: GameRoomGames::CATALOG,
      mode_label: 'Local test — this computer only',
      actor: 'Testowa Żaneta', timezone: ZONE.dup, clock: -> { 100 },
      convert_time: ->(date, _time) { date == '2026-10-01' ? 100 : 200 },
      save: ->(**_values) { raise 'Nieoczekiwany zapis' }, alert: ->(message) { raise message } }.merge(options)
  end

  def field(form, header)
    form.fields.find { |control| control.respond_to?(:header) && control.header == header } || raise("Brak pola #{header}")
  end

  def button(form, label = PUBLISH)
    form.fields.find { |control| control.is_a?(Button) && control.label == label } || raise("Brak przycisku #{label}")
  end

  def fill(form, rules: 'Graj uczciwie. Żółć.')
    rules_field = field(form, RULES)
    # Surowe wejścia walidatora (np. uszkodzone UTF8) w lekkiej atrapie.
    if defined?(FakeControl)
      rules_field.text = rules
    else
      rules_field.set_text(rules)
    end
    %w[closes].each do |kind|
      parts = %w[year month day hour minute]
      [2026, 10, 2, 12, 0].each_with_index do |value, part|
        control = field(form, "Registration #{kind}: #{parts[part]}")
        control.index = control.options.index(format(part.zero? ? '%04d' : '%02d', value)) || raise('Brak wartości')
        control.trigger(:move)
      end
    end
  end

  def readonly?(field)
    field.is_a?(EditBox) && (field.flags & EditBox::Flags::ReadOnly) != 0
  end

  def document(form)
    form.fields.reject { |control| control.is_a?(Button) || control.header == 'Status' }.map do |control|
      [control.header, control.is_a?(ListBox) ? control.options[control.index] : control.text]
    end
  end

  # Lekka atrapa zachowuje natywną kolejność before_focus/focus.
  module Script
    def focus(*_args)
      control = fields[index]
      control.trigger(:before_focus)
      control.focus(index, fields.length)
      control.trigger(:focus)
    end

    def wait
      super
      ($publication_editor_step || raise('Brak scenariusza')).call(self)
    end
  end
end
