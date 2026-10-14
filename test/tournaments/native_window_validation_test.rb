# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_window_fields'
require_relative '../../lib/tournaments/draft_details_editor'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })

header = 'Start: year'
# Nowe okno domyślnie ma pełne minuty 00, lecz nadal wymaga dnia i godzin.
driver = TournamentNativeDriver.new
driver.step(header, [27]) do |form|
  %w[Start End].each do |prefix|
    minutes = TournamentWindowTest.field(form, "#{prefix}: minute")
    assert(minutes.options[minutes.index] == '00', "Nowe okno nie ustawiło 00 w #{prefix}: minute")
    assert(TournamentWindowTest.field(form, "#{prefix}: hour").index.zero?, 'Domyślne minuty wymyśliły godzinę')
  end
  assert(TournamentWindowTest.field(form, 'Start: month').index.zero? && TournamentWindowTest.field(form, 'Start: day').index.zero?, 'Domyślne minuty wymyśliły datę')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
assert(result.nil?, 'Otwarcie lub anulowanie okna z domyślnymi minutami zapisało dane')
puts 'PASS nowe okno: minuty 00, godziny i dzień nieustalone, Escape bez zapisu'

# Pełna poprawna data, godziny 12 i 21, pominięte minuty początku.
driver = TournamentNativeDriver.new
alerts = []
driver.step(header) do |form|
  TournamentWindowTest.fill(form, date: '2026-10-02', start: '12:00', end_date: '', finish: '21:00')
  TournamentWindowTest.select(form, 'Start: minute', nil)
end
driver.press(header, 13)
driver.step(header, [27]) do |form|
  assert(alerts == ['Choose a value for Start: minute.'], "Brak wskazania minut, komunikaty: #{alerts.inspect}")
  assert(form.fields[form.index].header == 'Start: minute', 'Brak fokusu na brakujących minutach')
  assert(SpeechOutput.calls.last.first.start_with?('Start: minute'), 'Nie odczytano brakującego pola')
  assert(NVDA.calls.last.first.start_with?('Start: minute'), 'Brajl nie wskazuje brakującego pola')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { alerts << message }).wait
driver.finish
assert(result.nil?, 'Anulowanie niekompletnego okna zatwierdziło dane')
puts 'PASS nieustalone minuty: dokładny komunikat, fokus, mowa/brajl i anulowanie'

# Każda część daty i czasu, również osobna data końca: nie zmieniaj pozostałych wyborów.
%w[Start End].product(%w[year month day hour minute]).each do |prefix, part|
  label = "#{prefix}: #{part}"
  driver = TournamentNativeDriver.new
  alerts, before_choices = [], nil
  original = { 'date' => '2026-10-02', 'start' => '12:00', 'end_date' => '2026-10-03', 'end' => '21:00' }
  before = JSON.generate(original)
  driver.step(header) do |form|
    TournamentWindowTest.select(form, label, nil)
    before_choices = TournamentWindowTest.choices(form)
    missing = TournamentWindowTest.field(form, label)
    # Fokus po informacji nie może dopuścić ponownego zapisu ani anulowania.
    [:before_focus, :focus].each do |event|
      missing.on(event) { form.accept_button.trigger(:press); form.cancel_button.trigger(:press) }
    end
  end
  driver.press(header, 13)
  driver.step(header, [27]) do |form|
    assert(alerts == ["Choose a value for #{label}."], "Nieprawidłowe wskazanie #{label}")
    assert(form.fields[form.index].header == label, "Fokus nie trafił do #{label}")
    assert(TournamentWindowTest.choices(form) == before_choices, 'Walidacja zmieniła inne wybory')
    assert(SpeechOutput.calls.last.first.start_with?(label) && NVDA.calls.last.first.start_with?(label), 'Brak mowy/brajla pola')
  end
  result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
    window: original, windows: [original], index: 0, alert: lambda { |message|
      alerts << message
      form = driver.forms.last
      form.accept_button.trigger(:press)
      form.cancel_button.trigger(:press)
    }).wait
  driver.finish
  assert(result.nil? && JSON.generate(original) == before, 'Anulowanie lub reentry zmieniło dane wejściowe')
end
puts 'PASS wszystkie części obu terminów: dokładny brak, niezmienność wyborów, anulowanie i reentry alert/fokus'

# Przypadek użytkownika: wybrane 12 i 21 bez dotykania minut. Wyłącznie klawiatura hosta.
driver = TournamentNativeDriver.new
alerts = []
driver.press(header, 39)
driver.press(header, 40)
driver.press(header, 39)
2.times { driver.press(header, 40) }
driver.press(header, 39)
(12 + 1).times { driver.press(header, 40) }
[39, 9, 9].each { |key| driver.press(header, key) }
(21 + 1).times { driver.press(header, 40) }
driver.step(header, [13]) do |form|
  assert(TournamentWindowTest.field(form, 'Start: hour').options[TournamentWindowTest.field(form, 'Start: hour').index] == '12', 'Nie wybrano godziny 12')
  assert(TournamentWindowTest.field(form, 'End: hour').options[TournamentWindowTest.field(form, 'End: hour').index] == '21', 'Nie wybrano godziny 21')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { alerts << message }).wait
driver.finish
date = format('%04d-01-02', Time.now.year)
assert(alerts.empty?, 'Domyślne minuty nadal wymagają ręcznego wyboru')
assert(result == { 'date' => date, 'start' => '12:00', 'end_date' => date, 'end' => '21:00' }, 'Poprawa minut nie przyjęła 12:00–21:00 tego samego dnia')
puts 'PASS prawdziwa klawiatura: wybrane godziny 12–21 bez dotykania minut, zapis 12:00–21:00 bez błędu'
