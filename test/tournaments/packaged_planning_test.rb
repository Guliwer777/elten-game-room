# encoding: UTF-8
require 'tmpdir'
require_relative '../support/binary_rules_load'
require_relative '../support/tournament_window_fields'

# Natywne Tasks wymagają pompy hosta; próba nie otwiera żywego GUI.
def loop_update
  Thread.pass
end

def assert(condition, message)
  raise message unless condition
end

def caption(message)
  $planning_language == 'pl' ? RULES_CATALOG.fetch(message) : message
end

def field(form, header)
  form.fields.find { |control| control.respond_to?(:header) && control.header == caption(header) } || raise("Brakuje pola: #{header}")
end

def button(form, label)
  form.fields.find { |control| control.respond_to?(:label) && control.label == caption(label) } || raise("Brakuje przycisku: #{label}")
end

module PackagedPlanningForms
  # Kontrakt src/ui/form.rb:562–568; lekka atrapa nie ma tej metody.
  def focus(*_arguments)
    control = fields[index]
    return unless control
    control.trigger(:before_focus)
    control.focus(index, fields.length)
    control.trigger(:focus)
  end

  def wait
    super
    fields.each do |control|
      values = []
      values << control.header if control.respond_to?(:header) && control.header
      values << control.label if control.respond_to?(:label)
      values << control.text if control.respond_to?(:text)
      values.concat(control.options) if control.respond_to?(:options)
      invalid = values.reject { |value| value.is_a?(String) && value.valid_encoding? && value.encoding == Encoding::UTF_8 }
      assert(invalid.empty?, "Binarne lub uszkodzone napisy formularza #{control.class}: #{invalid.map { |value| [value, value.respond_to?(:encoding) ? value.encoding : value.class] }.inspect}")
    end
    ($planning_steps.shift || raise('Nieoczekiwany formularz')).call(self)
  end
end
Form.prepend(PackagedPlanningForms)

registry = EltenGameRoom::GAME_REGISTRY
languages = ENV.fetch('TOURNAMENT_TEST_LANGUAGES', 'en pl').split
raise 'Wybierz wyłącznie en lub pl' if languages.empty? || (languages - %w[en pl]).any?
languages.each do |language|
  $planning_language = language
  GameRoomTestLocalization.use_language(language)
  Dir.mktmpdir('tournament-planning-', ENV.fetch('TMPDIR')) do |directory|
    program = Object.new
    program.define_singleton_method(:data_path) { directory }
    alerts = []
    workspace = lambda do
      GameRoomTournaments::DraftWorkspace.new(program: program, registry: registry,
        user: -> { 'IzolowanyTester' }, alert: ->(message) { alerts << message }, confirm: ->(*) { raise 'Nieoczekiwane usuwanie' })
    end
    names = ['Żaneta', 'Łukasz', 'Celina', 'Darek', 'Ewa']
    $planning_steps = [lambda do |form|
      button(form, 'New draft').trigger(:press)
      assert(field(form, 'Tournament drafts').options.one?, 'Nie odświeżono listy po zapisie')
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      field(form, 'Tournament name').text = 'Jesienny — próba'
      field(form, 'Game').index = registry.ids.index('three_five_eight') + 1
      field(form, 'Tournament format').index = 1
      field(form, 'Return matches').index = 1
      button(form, 'Participants and playing windows').trigger(:press)
      form.accept_button.trigger(:press)
    end, lambda do |form|
      field(form, 'Participants (one name per line; local list)').text = names.join("\r\n")
      field(form, 'Players per match').index = 2
      field(form, 'Multiplayer pairings').index = 2
      button(form, 'Add window').trigger(:press)
      form.accept_button.trigger(:press)
    end, lambda do |form|
      %w[Start End].each do |prefix|
        minute = field(form, "#{prefix}: minute")
        assert(minute.options[minute.index] == '00', 'Paczka nie ustawiła domyślnych minut 00')
      end
      TournamentWindowTest.fill(form, date: '2026-10-03', start: '18:00', end_date: '', finish: '21:00', translate: method(:caption))
      TournamentWindowTest.select(form, 'End: minute', nil, translate: method(:caption))
      form.accept_button.trigger(:press)
      expected = format(caption('Choose a value for %{field}.'), field: caption('End: minute'))
      assert(alerts == [expected] && alerts.first.encoding == Encoding::UTF_8 && alerts.first.valid_encoding?, 'Binarna walidacja nie podała brakujących minut po polsku/angielsku')
      assert(form.fields[form.index].equal?(field(form, 'End: minute')), 'Binarna walidacja nie przywróciła fokusu')
      assert(form.instance_variable_get(:@wait) != false, 'Błąd zamknął formularz')
      alerts.clear
      TournamentWindowTest.select(form, 'End: minute', 0, translate: method(:caption))
      form.accept_button.trigger(:press)
    end]
    workspace.call.run
    assert($planning_steps.empty?, 'Nie wykonano pełnej ścieżki tworzenia')
    assert(alerts == [caption('Draft saved locally. It has not been published.')], "Nieoczekiwane komunikaty: #{alerts.inspect}")
    saved = workspace.call.load.fetch(0)
    assert(saved['participants'] == names && saved['players_per_match'] == 3 && saved['pairing'] == 'balanced_cycle', 'Zgubione ustawienia składów')
    assert(saved['windows'] == [{ 'date' => '2026-10-03', 'start' => '18:00', 'end_date' => '2026-10-03', 'end' => '21:00' }], 'Nie utrwalono okna')
    path = File.join(directory, Dir.children(directory).find { |name| name.end_with?('.json') })
    before = File.binread(path)
    $planning_steps = [lambda do |form|
      list = field(form, 'Tournament drafts')
      index = list.index
      assert(form.accept_button.label == caption('View draft'), 'Enter otwiera edycję')
      form.accept_button.trigger(:press)
      assert(list.index == index && form.fields[form.index].equal?(list), 'Powrót zgubił fokus lub zaznaczenie')
      button(form, 'Edit draft').trigger(:press)
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      description = field(form, 'Tournament settings').text
      ['Jesienny — próba', 'Żaneta', '2026-10-03', '18:00', '21:00'].each { |part| assert(description.include?(part), "Brak w podglądzie: #{part}") }
      button(form, 'Match plan').trigger(:press)
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      assert(field(form, 'Matches').options.length == 5, 'Błędna liczba składów rotacyjnych')
      summary = field(form, 'Plan summary').text
      names.each { |name| assert(summary.include?("#{name}: 3"), 'Nieprawidłowa liczba występów') }
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      button(form, 'Participants and playing windows').trigger(:press)
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      assert(field(form, 'Participants (one name per line; local list)').text.split(/\r?\n/) == names, 'Ponowne otwarcie zgubiło uczestników')
      assert(field(form, 'Playing windows').options.one?, 'Ponowne otwarcie zgubiło okno')
      field(form, 'Participants (one name per line; local list)').text = 'Tylko lokalna zmiana'
      form.accept_button.trigger(:press)
    end]
    workspace.call.run
    assert($planning_steps.empty?, 'Nie wykonano pełnej ścieżki podglądu i anulowania')
    assert(File.binread(path) == before, 'Podgląd, plan albo anulowanie zmieniły zapisany plik')
    assert(workspace.call.load.fetch(0) == saved, 'Zmieniła się rewizja lub dane szkicu')
  end
  puts "PASS binarne #{language}: lista → edycja → uczestnicy/okno → zapis → ponowne otwarcie → Enter/podgląd → plan → anulowanie bez zapisu"
end
