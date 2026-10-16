# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_window_fields'
require_relative '../../lib/tournaments/draft_details_editor'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })

HEADER = 'Start: year'.freeze
window = { 'date' => '2026-10-03', 'start' => '10:15', 'end_date' => '2026-10-03', 'end' => '12:45' }
before = JSON.generate(window)
driver = TournamentNativeDriver.new
driver.press(HEADER, 39) do |form|
  assert(form.fields.first.instance_of?(ListBox), 'Rok musi używać natywnego ListBox')
  assert(form.fields.first.options[form.fields.first.index] == '2026', 'Nie odtworzono roku')
end
driver.step(HEADER, [27]) do |form|
  assert(form.index == 1 && form.fields[1].header == 'Start: month', 'Prawo nie przeszło do miesiąca')
  assert(form.fields.first.options[form.fields.first.index] == '2026', 'Prawo zmieniło rok')
  assert(form.fields[1].options[form.fields[1].index] == '10', 'Prawo zmieniło miesiąc')
  assert(SpeechOutput.calls.last.first.start_with?('Start: month'), 'Brak mowy nowego składnika')
  assert(NVDA.calls.last.first.start_with?('Start: month'), 'Brak brajla nowego składnika')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: window, windows: [window], index: 0, alert: ->(message) { raise message }).wait
driver.finish
assert(result.nil? && JSON.generate(window) == before, 'Escape zmienił okno')
puts 'PASS natywny wybierak: Prawo przenosi fokus bez zmiany roku/miesiąca; Escape nie zapisuje'

# Nowy termin nie jest gotowym oknem. Rok to wyłącznie pozycja listy.
driver = TournamentNativeDriver.new
alerts = []
driver.step(HEADER, [13]) do |form|
  assert(form.fields.first.options[form.fields.first.index] == format('%04d', Time.now.year), 'Nowy rok nie wskazuje bieżącego lokalnego roku')
  assert(TournamentWindowTest.choices(form).values_at(1, 2, 3, 8).all? { |value| value == 'To be decided' }, 'Nowe okno wymyśliło dzień lub godzinę')
  assert(TournamentWindowTest.choices(form).values_at(4, 9) == ['00', '00'], 'Nowe okno nie ustawiło domyślnych minut 00')
  assert(TournamentWindowTest.same_day(form).checked, 'Nowy koniec nie ma daty początku')
end
driver.step(HEADER) do |form|
  assert(alerts == ['Choose a value for Start: month.'] && form.index == 1, 'Enter bez kompletu nie wskazał brakującego miesiąca')
  TournamentWindowTest.fill(form, date: '2026-10-03', start: '00:00', end_date: '', finish: '00:01')
end
driver.step(HEADER, [13])
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { alerts << message }).wait
driver.finish
assert(result == { 'date' => '2026-10-03', 'start' => '00:00', 'end_date' => '2026-10-03', 'end' => '00:01' }, 'Północ pomylona z brakiem lub zły format zapisu')
puts 'PASS rok startowy bez pełnego terminu; Enter odrzuca braki i zatwierdza północ z końcem tego samego dnia'

# Zmiana miesiąca ma wycofać nieistniejący dzień, nie przycinać go do końca miesiąca.
driver = TournamentNativeDriver.new
invalidations = []
window = { 'date' => '2026-01-31', 'start' => '10:15', 'end_date' => '2026-01-31', 'end' => '12:45' }
driver.press(HEADER, 39)
driver.press(HEADER, 40)
driver.step(HEADER, [27]) do |form|
  day = TournamentWindowTest.field(form, 'Start: day')
  assert(day.options == ['To be decided'] + (1..28).map { |value| format('%02d', value) }, 'Luty oferuje nieistniejące dni')
  assert(day.index == 0 && form.index == 1, 'Zmiana miesiąca przycięła dzień lub zabrała fokus')
  assert(invalidations.one? && invalidations.first.include?('Start: day'), 'Brak jasnej informacji o wycofaniu dnia')
  assert(TournamentWindowTest.values(form).values_at(1, 3) == ['10:15', '12:45'], 'Zmiana miesiąca zgubiła godziny')
end
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: window, windows: [window], index: 0, alert: ->(message) { invalidations << message }).wait
driver.finish
puts 'PASS luty usuwa niedostępny 31. dzień do jawnego nieustalonego, zachowuje godziny i fokus'

# Koniec wybierany osobno zaczyna od wybranej daty początku, nie arbitralnego dnia.
driver = TournamentNativeDriver.new
driver.step(HEADER) do |form|
  TournamentWindowTest.fill(form, date: '2032-02-29', start: '23:10', end_date: '', finish: '23:50')
end
5.times { driver.press(HEADER, 9) }
driver.press(HEADER, 32)
driver.step(HEADER) do |form|
  assert(form.index == 5 && !TournamentWindowTest.same_day(form).checked, 'Spacja zmieniła fokus zamiast checkboxa')
  assert(TournamentWindowTest.values(form)[2] == '2032-02-29', 'Osobny koniec nie przejął daty początku')
end
driver.press(HEADER, 9)
driver.step(HEADER, [27]) do |form|
  assert(form.fields[form.index].header == 'End: year', 'Tab pominął odkryty rok końca')
  assert(SpeechOutput.calls.last.first.start_with?('End: year'), 'Brak odczytu odkrytej daty')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
assert(result.nil?, 'Anulowany wybór końca przekazał dane')
puts 'PASS natywne Tab/Spacja odkrywają osobną datę końca i inicjują ją datą początku'

# F1 używa wspólnego dialogu pomocy i nie zatwierdza okna pod nim.
driver = TournamentNativeDriver.new
driver.step(HEADER) { |form| form.game_room_hotkey_action(1).call }
driver.step('Keyboard shortcuts', [27]) do |form|
  help = form.fields.first.text
  assert(help.include?('Up/Down') && help.include?('Left/Right') && help.include?('Tab') && help.include?('Enter') && help.include?('Escape'), 'Brak pomocy klawiszy wybieraka w F1')
end
driver.step(HEADER, [27]) do |form|
  assert(form.index.zero? && SpeechOutput.calls.last.first.start_with?(HEADER), 'Pomoc nie odtworzyła fokusu/odczytu')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
assert(result.nil?, 'Pomoc zatwierdziła nieuzupełnione okno')
puts 'PASS F1: krótka pomoc wybieraka, natywny dialog i powrót bez zatwierdzenia'

# Bez roku można wybrać 29 lutego, lecz nie nieistniejący 30/31 lutego.
driver = TournamentNativeDriver.new
driver.step(HEADER, [27]) do |form|
  TournamentWindowTest.select(form, 'Start: year', nil)
  TournamentWindowTest.select(form, 'Start: month', 2)
  assert(TournamentWindowTest.field(form, 'Start: day').options == ['To be decided'] + (1..29).map { |day| format('%02d', day) }, 'Luty bez roku oferuje nieistniejący dzień')
end
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS niepełna data: luty bez roku ma najwyżej 29 dni'

# Pełne nowe okno, bez pomocniczego ustawiania indeksów: tylko klawiatura hosta.
driver = TournamentNativeDriver.new
[39, 40, 39, 40, 39, 40, 39, 9, 9, 40, 39, 40].each { |key| driver.press(HEADER, key) }
driver.step(HEADER, [13]) do |form|
  assert(form.fields[form.index].header == 'End: minute', 'Klawiatura nie osiągnęła minut końca')
end
result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
date = format('%04d-01-01', Time.now.year)
assert(result == { 'date' => date, 'start' => '00:00', 'end_date' => date, 'end' => '00:01' }, 'Klawiaturowe utworzenie zmieniło cywilne dane')
puts 'PASS całe nowe okno: tylko natywne Prawo/Dół/Tab/Enter, bez wpisywania tekstu'

# Każda lista zmienia tylko własny składnik i ogłasza wartość natywną mowę/brajlem.
window = { 'date' => '2026-10-03', 'start' => '10:15', 'end_date' => '2026-10-03', 'end' => '12:45' }
driver = TournamentNativeDriver.new
original_choices = nil
driver.step(HEADER) { |form| original_choices = TournamentWindowTest.choices(form) }
5.times do |part|
  driver.press(HEADER, 40)
  driver.step(HEADER) do |form|
    control = form.fields[part]
    expected = original_choices.dup
    expected[part] = format(part.zero? ? '%04d' : '%02d', original_choices[part].to_i + 1)
    assert(form.index == part && TournamentWindowTest.choices(form) == expected, "Dół zmienił zły składnik #{part}")
    assert(SpeechOutput.calls.last.first == expected[part], "Dół nie wypowiedział wartości #{part}")
    assert(NVDA.calls.last.first.include?(control.header) && NVDA.calls.last.first.include?(expected[part]), 'Brajl nie pokazuje składnika i wartości')
  end
  driver.press(HEADER, 38)
  driver.step(HEADER) { |form| assert(TournamentWindowTest.choices(form) == original_choices, 'Góra nie przywróciła wartości') }
  driver.press(HEADER, 39)
end
driver.step(HEADER) { |form| assert(form.index == 4, 'Prawo po ostatniej części początku zawija lub przechodzi do końca') }
4.times { driver.press(HEADER, 37) }
driver.press(HEADER, 37)
driver.step(HEADER, [27]) { |form| assert(form.index.zero?, 'Lewo przed rokiem zawija') }
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: window, windows: [window], index: 0, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS wszystkie części początku: Góra/Dół ogłaszają tylko zmienioną wartość; Lewo/Prawo bez zawijania'

# Kombinacje z modyfikatorami należą do hosta, nigdy do przejścia między częściami.
driver = TournamentNativeDriver.new
state = nil
driver.press(HEADER, 39)
driver.step(HEADER) { |form| state = TournamentWindowTest.choices(form) }
[[16], [17], [18], [45], [16, 17, 18, 45]].each do |modifiers|
  [37, 39, 38, 40].each do |key|
    driver.step(HEADER, modifiers + [key])
    driver.step(HEADER) do |form|
      assert(form.index == 1 && TournamentWindowTest.choices(form) == state, "Przechwycono kombinację #{modifiers.inspect}/#{key}")
    end
  end
end
driver.step(HEADER, [27])
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: window, windows: [window], index: 0, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS Ctrl/Alt/Shift/Insert: brak przejęcia kombinacji strzałek'

# Tab/Shift+Tab łączą checkbox, widoczne części końca i przyciski.
driver = TournamentNativeDriver.new
5.times { driver.press(HEADER, 9) }
driver.step(HEADER) { |form| assert(form.index == 5, 'Tab pominął checkbox') }
driver.press(HEADER, 9)
driver.step(HEADER) { |form| assert(form.fields[form.index].header == 'End: hour', 'Tab nie pominął ukrytych dat') }
driver.press(HEADER, 37)
driver.step(HEADER) { |form| assert(form.fields[form.index].header == 'End: hour', 'Lewo weszło w ukrytą datę') }
driver.press(HEADER, 39)
driver.press(HEADER, 39)
driver.step(HEADER) { |form| assert(form.fields[form.index].header == 'End: minute', 'Prawo zawinęło koniec') }
driver.press(HEADER, 9)
driver.step(HEADER) { |form| assert(form.fields[form.index].equal?(form.accept_button), 'Tab nie osiągnął zatwierdzenia') }
driver.step(HEADER, [16, 9])
driver.step(HEADER) { |form| assert(form.fields[form.index].header == 'End: minute', 'Shift+Tab nie cofnął na minuty') }
driver.press(HEADER, 37)
driver.step(HEADER, [16, 9])
driver.step(HEADER) { |form| assert(form.index == 5, 'Shift+Tab nie pominął ukrytych dat') }
driver.press(HEADER, 32)
driver.press(HEADER, 9)
4.times { driver.press(HEADER, 39) }
driver.press(HEADER, 39)
driver.step(HEADER) { |form| assert(form.fields[form.index].header == 'End: minute', 'Osobny koniec zawija') }
4.times { driver.press(HEADER, 37) }
driver.press(HEADER, 37)
driver.step(HEADER, [27]) { |form| assert(form.fields[form.index].header == 'End: year', 'Lewo na początku osobnego końca zawija') }
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: window, windows: [window], index: 0, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS Tab/Shift+Tab, checkbox i lokalne strzałki końca: ukryte daty pomijane, bez zawijania'

# Niekompletny początek nie tworzy pozornej pełnej daty końca.
driver = TournamentNativeDriver.new
driver.step(HEADER) { |form| TournamentWindowTest.select(form, 'Start: year', 1999) }
5.times { driver.press(HEADER, 9) }
driver.press(HEADER, 32)
driver.step(HEADER, [27]) do |form|
  assert(TournamentWindowTest.choices(form).values_at(5, 6, 7) == [format('%04d', Time.now.year), 'To be decided', 'To be decided'], 'Osobny koniec dostał arbitralną datę')
end
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS osobny koniec przy niepełnym początku: tylko bieżący rok, reszta nieustalona'

# Pełny zakres lat i gregoriański kalendarz, również przed reformą 1582.
%w[0001-01-01 0004-02-29 0100-02-28 0400-02-29 1500-02-28 1582-10-10 1600-02-29 1700-02-28 1900-02-28 2000-02-29 2024-02-29 2025-04-30 9999-12-31].each do |date|
  driver = TournamentNativeDriver.new
  window = { 'date' => date, 'start' => '00:00', 'end_date' => date, 'end' => '23:59' }
  driver.step(HEADER, [13]) do |form|
    assert(TournamentWindowTest.values(form) == window.values_at('date', 'start', 'end_date', 'end'), "Otwarcie skorygowało #{date}")
    assert(form.fields.first.options == ['To be decided'] + (1..9999).map { |year| format('%04d', year) }, 'Lista lat zawęża stary zakres')
    assert(TournamentWindowTest.field(form, 'Start: hour').options == ['To be decided'] + (0..23).map { |hour| format('%02d', hour) }, 'Nieprawidłowy zakres godzin')
    assert(TournamentWindowTest.field(form, 'End: minute').options == ['To be decided'] + (0..59).map { |minute| format('%02d', minute) }, 'Nieprawidłowy zakres minut')
  end
  result = GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
    window: window, windows: [window], index: 0, alert: ->(message) { raise message }).wait
  driver.finish
  assert(result == window, "Zapis skorygował #{date}")
end
puts 'PASS granice lat 1..9999, gregoriańskie stulecia i 1582, brak korekty starych terminów'

# Zmiana roku przestępnego dotyczy tylko właściwego dnia, nigdy godziny/minuty.
%w[Start End].each do |prefix|
  driver = TournamentNativeDriver.new
  notices = []
  window = { 'date' => '2024-02-29', 'start' => '23:50', 'end_date' => '2028-02-29', 'end' => '00:10' }
  6.times { driver.press(HEADER, 9) } if prefix == 'End'
  driver.press(HEADER, 40)
  driver.step(HEADER, [27]) do |form|
    day = TournamentWindowTest.field(form, "#{prefix}: day")
    assert(day.index.zero? && !day.options.include?('29'), 'Rok nieprzestępny zachował 29 lutego')
    assert(notices.one? && notices.first.include?("#{prefix}: day"), 'Brak informacji o właściwym dniu')
    assert(TournamentWindowTest.values(form).values_at(1, 3) == ['23:50', '00:10'], 'Zmiana roku utraciła nocne godziny')
  end
  GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: Object.new,
    window: window, windows: [window], index: 0, alert: ->(message) { notices << message; alert(message, false) }).wait
  driver.finish
  assert(SpeechOutput.calls.any? { |call| call.first.include?('Choose the day again') }, 'Informacja o dniu nie dotarła do natywnej mowy')
end
puts 'PASS rok przestępny obu końców: wycofanie 29 lutego, odczyt i nienaruszone nocne godziny'

# Informacja o wycofaniu dnia również podlega guardowi dziecka i rodzica.
parent_header = 'Participants (one name per line; local list)'
window = { 'date' => '2026-01-31', 'start' => '10:15', 'end_date' => '2026-01-31', 'end' => '12:45' }
details = { 'participants' => [], 'windows' => [window], 'players_per_match' => nil, 'pairing' => nil }
before = JSON.generate(details)
driver = TournamentNativeDriver.new
parent = child = nil
notices = []
5.times { driver.press(parent_header, 9) }
driver.step(parent_header, [13]) { |form| parent = form }
driver.step(HEADER) { |form| child = form }
driver.press(HEADER, 39)
driver.press(HEADER, 40)
driver.step(HEADER) do |form|
  assert(notices.one? && form.index == 1 && form.instance_variable_get(:@wait), 'Alert dnia zamknął lub przestawił dziecko')
  assert(TournamentWindowTest.field(form, 'Start: day').index.zero?, 'Alert dnia zgubił wycofanie wyboru')
  TournamentWindowTest.select(form, 'Start: day', 28)
end
driver.step(HEADER, [13])
driver.step(parent_header, [27]) do |form|
  assert(form.index == 5 && SpeechOutput.calls.last.first.start_with?('Edit window') && NVDA.calls.last.first.start_with?('Edit window'), 'Powrót po alercie utracił prezentację rodzica')
  assert(form.fields[3].options == ['2026-02-28 10:15 - 2026-02-28 12:45'], 'Poprawa dnia nie wróciła do lokalnego rodzica')
end
result = GameRoomTournaments::DraftDetailsEditor.new(program: Object.new, details: details, alert: lambda do |message|
  notices << message
  count = driver.forms.length
  2.times do
    [parent, child].each { |form| form.accept_button.press; form.cancel_button.press }
    parent.fields.select { |field| field.is_a?(Button) && ['Add window', 'Edit window', 'Remove window'].include?(field.label) }.each(&:press)
  end
  assert(driver.forms.length == count && parent.instance_variable_get(:@wait) && child.instance_variable_get(:@wait), 'Alert dnia zwolnił guard modalnej operacji')
end).wait
driver.finish
assert(result.nil? && JSON.generate(details) == before, 'Anulowanie rodzica zapisało poprawiony termin')
puts 'PASS guard informacji o dniu: wielokrotne Enter/Escape/Add/Edit/Remove bez reentrancji; powrót mowy/brajla rodzica'

# Wspólne skróty głośności zachowują program i nie dotykają wyboru terminu.
driver = TournamentNativeDriver.new
volume_keys = []
program = Object.new
program.define_singleton_method(:adjust_game_room_volume) { |key, **_options| volume_keys << key }
driver.step(HEADER, [27]) do |form|
  state = TournamentWindowTest.choices(form)
  [2, 3, -2, -3].each { |key| form.game_room_hotkey_action(key).call }
  assert(volume_keys == [2, 3, -2, -3] && form.index.zero? && TournamentWindowTest.choices(form) == state, 'F2/F3 lub Shift+F2/F3 zmieniły wybierak zamiast wspólnej głośności')
end
GameRoomTournaments::DraftDetailsEditor::WindowEditor.new(program: program,
  window: {}, windows: [], index: nil, alert: ->(message) { raise message }).wait
driver.finish
puts 'PASS wspólne akcje F2/F3 i Shift+F2/F3 zachowane bez ingerencji wybieraka'
