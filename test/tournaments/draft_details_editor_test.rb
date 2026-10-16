# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_window_fields'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/draft_details_editor.rb', __dir__)
require source if File.file?(source)
def assert(condition, message)
  raise message unless condition
end
assert(defined?(GameRoomTournaments::DraftDetailsEditor), 'Brakuje edytora uczestników i okien')
module DraftDetailsScript
  # Native src/ui/form.rb:562-568; keep the contract local to this light fake.
  def focus(*_arguments)
    control = fields[index]
    return unless control
    control.trigger(:before_focus)
    control.focus(index, fields.length)
    control.trigger(:focus)
  end

  def wait
    super
    ($draft_details_steps.shift || raise('Nieoczekiwany formularz')).call(self)
  end

  def resume
    @draft_details_resume_count = (@draft_details_resume_count || 0) + 1
    super
  end
end
Form.prepend(DraftDetailsScript)
def field(form, header)
  form.fields.find { |item| item.respond_to?(:header) && item.header == header } || raise("Brakuje pola #{header}")
end
def button(form, label)
  form.fields.find { |item| item.respond_to?(:label) && item.label == label } || raise("Brakuje przycisku #{label}")
end
program = Object.new
original = { 'participants' => ['Poprzedni'], 'windows' => [], 'players_per_match' => nil, 'pairing' => nil }
before = JSON.generate(original)
$draft_details_steps = [lambda do |form|
  assert(form.game_room_program.equal?(program), 'Formularz nie ma programu')
  names = field(form, 'Participants (one name per line; local list)')
  assert(form.fields[form.index].equal?(names) && names.text == 'Poprzedni', 'Zły fokus lub lista uczestników')
  names.text = " Ala \r\nBartek\r\nCelina\r\n\r\nDarek\r\nEwa\r\nFilip"
  field(form, 'Players per match').index = 2
  field(form, 'Multiplayer pairings').index = 2
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result == { 'participants' => %w[Ala Bartek Celina Darek Ewa Filip], 'windows' => [],
  'players_per_match' => 3, 'pairing' => 'balanced_cycle', 'group_count' => nil, 'places_per_group' => nil, 'group_advancement' => nil }, 'Nie zapisano ustawień organizatora')
assert(JSON.generate(original) == before, 'Edytor zmienił przekazany szkic')
puts 'PASS lokalni uczestnicy i jawny wybór liczby graczy oraz składów'

def window_values(form)
  TournamentWindowTest.values(form)
end

def window_state(form)
  [TournamentWindowTest.choices(form), TournamentWindowTest.same_day(form).checked]
end

def enter_window(form, date:, start:, end_date:, finish:)
  TournamentWindowTest.fill(form, date: date, start: start, end_date: end_date, finish: finish)
end

def details_with(windows = [])
  { 'participants' => [], 'windows' => windows, 'players_per_match' => nil, 'pairing' => nil,
    'group_count' => nil, 'places_per_group' => nil, 'group_advancement' => nil }
end

def playing_window(date = '2026-10-03', start = '10:15', end_date = date, finish = '12:45')
  { 'date' => date, 'start' => start, 'end_date' => end_date, 'end' => finish }
end

original = details_with
before = JSON.generate(original)
main = nil
$draft_details_steps = [lambda do |form|
  main = form
  list = field(form, 'Playing windows')
  assert(list.options.empty?, 'Nowy szkic dostał domyślne okna')
  form.index = form.fields.index(button(form, 'Add window'))
  focus = form.index
  button(form, 'Add window').trigger(:press)
  assert(form.index == focus, 'Dodanie okna niepotrzebnie przeniosło fokus')
  assert(list.options == ['2026-10-03 10:15 - 2026-10-03 12:45'], 'Wiersz nie pokazuje obu dat i godzin')
  assert(form.instance_variable_get(:@wait) != false, 'Zapis okna zamknął ustawienia')
  assert(JSON.generate(original) == before, 'Dodanie okna zapisało dane wejściowe')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  assert(dialog.is_a?(GameRoomUI::Form) && dialog.game_room_program.equal?(program), 'Okno pomija wspólny formularz')
  assert(window_values(dialog) == ['', '', '', ''], 'Dodawanie wymyśliło daty lub godziny')
  assert(dialog.fields.first.is_a?(ListBox) && dialog.index == 0, 'Brak natywnego pola i początkowego fokusu')
  assert(dialog.accept_button.label == 'Use this window' && dialog.cancel_button.label == 'Cancel', 'Złe przyciski okna')
  enter_window(dialog, date: '2026-10-03', start: '10:15', end_date: '2026-10-03', finish: '12:45')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result == details_with([playing_window]), 'Dodanie nie zwróciło lokalnego okna')
assert(JSON.generate(original) == before && $draft_details_steps.empty?, 'Naruszono wejście lub pominięto dialog')
puts 'PASS dodanie okna: puste pola, wspólny formularz i lokalne zatwierdzanie'

night = playing_window('2026-10-03', '23:10', '2026-10-04', '02:05')
original = details_with([playing_window('2026-11-03'), night])
before = JSON.generate(original)
$draft_details_steps = [lambda do |form|
  list = field(form, 'Playing windows')
  list.index = 1
  assert(list.options.last == '2026-10-03 23:10 - 2026-10-04 02:05', 'Nocny wiersz zgubił datę końca')
  form.index = form.fields.index(button(form, 'Edit window'))
  focus = form.index
  button(form, 'Edit window').trigger(:press)
  assert(list.index == 1 && form.index == focus, 'Edycja zgubiła zaznaczenie lub fokus')
  assert(list.options == ['2026-11-03 10:15 - 2026-11-03 12:45', '2026-10-24 23:15 - 2026-10-25 02:40'], 'Edycja zmieniła kolejność lub wartości okien')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  assert(window_values(dialog) == night.values_at('date', 'start', 'end_date', 'end'), 'Odtworzenie zmieniło zapisane okno nocne')
  enter_window(dialog, date: '2026-10-24', start: '23:15', end_date: '2026-10-25', finish: '02:40')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result['windows'] == [playing_window('2026-11-03'), playing_window('2026-10-24', '23:15', '2026-10-25', '02:40')], 'Nocna edycja nie zachowała cywilnych wartości')
assert(JSON.generate(original) == before, 'Edycja zmieniła wejście')
puts 'PASS edycja nocnego okna bez zmiany strefy, kolejności, fokusu i zaznaczenia'

original = details_with([playing_window(), playing_window('2026-10-04'), playing_window('2026-10-05')])
before = JSON.generate(original)
$draft_details_steps = [lambda do |form|
  list = field(form, 'Playing windows')
  list.index = 1
  form.index = form.fields.index(button(form, 'Remove window'))
  focus = form.index
  button(form, 'Remove window').trigger(:press)
  assert(list.options == ['2026-10-03 10:15 - 2026-10-03 12:45', '2026-10-05 10:15 - 2026-10-05 12:45'], 'Usunięto niewłaściwe okno')
  assert(list.index == 1 && form.index == focus, 'Usunięcie zgubiło najbliższy wiersz lub fokus')
  assert(JSON.generate(original) == before, 'Usunięcie dotknęło wejściowego szkicu')
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result['windows'] == [original['windows'][0], original['windows'][2]], 'Usunięcie nie dotyczyło lokalnej kopii')
puts 'PASS usunięcie wskazanego okna tylko z lokalnej kopii'

$draft_details_steps = [lambda do |form|
  button(form, 'Add window').trigger(:press)
  assert(field(form, 'Playing windows').options == ['2026-10-03 10:15 - 2026-10-03 12:45'], 'Pusta data końca nie otrzymała daty początku')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2026-10-03', start: '10:15', end_date: '', finish: '12:45')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: details_with, alert: ->(message) { raise message }).wait
assert(result == details_with([playing_window]), 'Pusta data końca nie została zapisana jawnie')
puts 'PASS pusta data końca oznacza datę początku'

WINDOW_ERROR = 'Enter valid dates and times, with the end after the start and no overlapping windows.'.freeze
alerts = []
main = nil
$draft_details_steps = [lambda do |form|
  main = form
  button(form, 'Add window').trigger(:press)
  assert(field(form, 'Playing windows').options == ['2026-10-03 10:15 - 2026-10-03 12:45'], 'Rodzic nie dostał poprawionego okna')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  # Nieistniejący dzień nie jest wybieralny; brak dnia nadal blokuje zatwierdzenie.
  enter_window(dialog, date: '2026-02-28', start: '10:15', end_date: '', finish: '12:45')
  assert(!field(dialog, 'Start: day').options.include?('30'), 'Luty oferuje dzień 30')
  TournamentWindowTest.select(dialog, 'Start: day', nil)
  dialog.index = 3
  typed = window_state(dialog)
  dialog.accept_button.trigger(:press)
  assert(dialog.instance_variable_get(:@wait) != false, 'Nieprawidłowa data zamknęła okno zamiast pozwolić na poprawę')
  assert(alerts == ['Choose a value for Start: day.'], 'Brak jasnego komunikatu o niewybranym dniu')
  assert(window_state(dialog) == typed && dialog.index == 2, 'Walidacja zgubiła wybory lub nie wskazała brakującego dnia')
  assert(field(main, 'Playing windows').options.empty?, 'Błędne okno trafiło do rodzica')
  TournamentWindowTest.date(dialog, 'Start', '2026-10-03')
  dialog.accept_button.trigger(:press)
  assert(dialog.instance_variable_get(:@wait) == false, 'Poprawa nie zamknęła okna')
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: details_with, alert: ->(message) { alerts << message }).wait
assert(result == details_with([playing_window]), 'Poprawa nie została przyjęta')
puts 'PASS błędna data zachowuje okno, tekst i fokus; poprawa bez odbudowy formularza'

alerts = []
original = details_with([playing_window])
before = JSON.generate(original)
$draft_details_steps = [lambda do |form|
  button(form, 'Add window').trigger(:press)
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2026-10-03', start: '12:30', end_date: '', finish: '13:00')
  dialog.accept_button.trigger(:press)
  assert(dialog.instance_variable_get(:@wait) != false && alerts == [WINDOW_ERROR], 'Nakładające się okno nie zostało zablokowane w dziecku')
  TournamentWindowTest.time(dialog, 'Start', '12:45')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { alerts << message }).wait
assert(result['windows'] == [playing_window, playing_window('2026-10-03', '12:45', '2026-10-03', '13:00')], 'Stykające się okna zostały odrzucone')
assert(JSON.generate(original) == before, 'Walidacja kandydata zmieniła oryginał')
puts 'PASS dziecko waliduje całą kandydacką listę i dopuszcza stykające się okna'

# Repeated events must not release an outer modal operation's guard.
def trigger_settings_actions(form)
  ['Add window', 'Edit window', 'Remove window', 'Use these settings', 'Cancel'].each do |label|
    button(form, label).trigger(:press)
  end
end

alerts = []
main = child = nil
$draft_details_steps = [lambda do |form|
  main = form
  button(form, 'Add window').trigger(:press)
  assert(form.instance_variable_get(:@wait) != false, 'Zdarzenia rodzica zamknęły zajęte ustawienia')
  assert(field(form, 'Playing windows').options == ['2026-10-03 10:15 - 2026-10-03 12:45'], 'Powtórny zapis dziecka zastąpił wynik')
  form.accept_button.trigger(:press)
  trigger_settings_actions(form)
end, lambda do |dialog|
  child = dialog
  enter_window(dialog, date: '', start: '10:15', end_date: '', finish: '12:45')
  state = window_state(dialog)
  dialog.accept_button.trigger(:press)
  assert(window_state(dialog) == state, 'Reentrant alert utracił częściowy wybór')
  assert(alerts == ['Choose a value for Start: year.'], 'Reentrant Use powieliło alert lub wskazało zły brak')
  assert(dialog.instance_variable_get(:@wait) != false, 'Reentrant Escape zamknął dziecko podczas alertu')
  assert(window_values(dialog) == ['', '10:15', '', '12:45'], 'Reentrant alert utracił tekst')
  TournamentWindowTest.date(dialog, 'Start', '2026-10-03')
  dialog.accept_button.trigger(:press)
  enter_window(dialog, date: '2026-10-06', start: '15:00', end_date: '', finish: '17:00')
  2.times { dialog.accept_button.trigger(:press); dialog.cancel_button.trigger(:press) }
end]
alert = lambda do |message|
  alerts << message
  if alerts.size == 1
    2.times do
      trigger_settings_actions(main)
      child.accept_button.trigger(:press)
      child.cancel_button.trigger(:press)
    end
  end
end
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: details_with, alert: alert).wait
assert(result == details_with([playing_window]) && $draft_details_steps.empty?, 'Powtórne zdarzenia nadpisały zaakceptowane ustawienia')
puts 'PASS guard dziecka i rodzica: reentrant alerty oraz powtórne Add/Edit/Remove/Use/Escape'

original = details_with([playing_window, playing_window('2026-10-04'), playing_window('2026-10-05')])
before = JSON.generate(original)
$draft_details_steps = [lambda do |form|
  list = field(form, 'Playing windows')
  keys = list.instance_variable_get(:@item_keys)&.dup
  assert(keys && keys.size == 3 && keys.uniq.size == 3 && !keys.include?(nil), 'Lista nie ma stabilnych item_keys')
  form.index = form.fields.index(button(form, 'Add window'))
  focus = form.index
  button(form, 'Add window').trigger(:press)
  added_keys = list.instance_variable_get(:@item_keys).dup
  assert(added_keys.take(3) == keys && added_keys.uniq.size == 4 && list.index == 3, 'Dodanie zmieniło stare klucze lub nie zaznaczyło nowego okna')
  list.index = 1
  button(form, 'Edit window').trigger(:press)
  assert(list.instance_variable_get(:@item_keys) == added_keys && list.index == 1, 'Edycja zmieniła tożsamość lub zaznaczenie okna')
  button(form, 'Remove window').trigger(:press)
  assert(list.instance_variable_get(:@item_keys) == [keys[0], keys[2], added_keys[3]] && list.index == 1, 'Usunięcie przesunęło tożsamości pozostałych okien')
  list.index = 2
  button(form, 'Remove window').trigger(:press)
  assert(list.index == 1, 'Usunięcie ostatniego nie zaznaczyło najbliższego okna')
  2.times { button(form, 'Remove window').trigger(:press) }
  assert(list.options.empty? && list.index == 0 && list.instance_variable_get(:@item_keys) == [], 'Pusta lista ma nieprawidłowy indeks lub klucze')
  button(form, 'Edit window').trigger(:press)
  button(form, 'Remove window').trigger(:press)
  button(form, 'Add window').trigger(:press)
  assert(list.index == 0 && (list.instance_variable_get(:@item_keys) & added_keys).empty?, 'Nowy wiersz po usunięciu przejął dawny klucz')
  assert(form.index == focus, 'Aktualizacja listy przesunęła fokus')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2026-10-06', start: '10:15', end_date: '', finish: '12:45')
  dialog.accept_button.trigger(:press)
end, lambda do |dialog|
  TournamentWindowTest.time(dialog, 'Start', '10:30')
  dialog.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2026-10-07', start: '10:15', end_date: '', finish: '12:45')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result == details_with([playing_window('2026-10-07')]) && JSON.generate(original) == before, 'Lista zmieniła dane wejściowe lub zwróciła stare okna')
puts 'PASS stabilne klucze, zaznaczenie dodanego/edytowanego/najbliższego i brak zmiany fokusu'

original = details_with([playing_window]).merge('id' => 'untouched', 'name' => 'Tournament', 'options' => { 'flag' => false })
before = JSON.generate(original)
$draft_details_steps = [->(form) { form.accept_button.trigger(:press) }]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result.keys.sort == GameRoomTournaments::DraftDetails::DEFAULTS.keys.sort, 'Ustawienia zwracają obce pola szkicu zamiast pól DEFAULTS')
assert(result == details_with([playing_window]) && JSON.generate(original) == before, 'Wycięcie pól utraciło ustawienia lub naruszyło szkic')
puts 'PASS wynik zawiera dokładnie pola DraftDetails::DEFAULTS'

invalid_windows = {
  'duplicate' => playing_window,
  'overlap' => playing_window('2026-10-03', '12:00', '2026-10-03', '13:00'),
  'contained' => playing_window('2026-10-03', '11:00', '2026-10-03', '12:00'),
  'overnight overlap' => playing_window('2026-10-02', '23:00', '2026-10-03', '11:00'),
  'bad start date' => playing_window('2026-02-30'),
  'bad end date' => playing_window('2026-10-06', '10:15', '2026-13-01'),
  'bad date format' => playing_window('2026-1-06'),
  'missing start date' => playing_window(''),
  'bad hour' => playing_window('2026-10-06', '24:00'),
  'bad minute' => playing_window('2026-10-06', '10:15', '2026-10-06', '12:60'),
  'bad time format' => playing_window('2026-10-06', '9:15'),
  'missing time' => playing_window('2026-10-06', ''),
  'equal endpoints' => playing_window('2026-10-06', '10:15', '2026-10-06', '10:15'),
  'reverse endpoints' => playing_window('2026-10-06', '10:15', '2026-10-05', '12:45')
}
invalid_windows.each do |label, invalid|
  ['Add window', 'Edit window'].each do |action|
    original = details_with([playing_window, playing_window('2026-10-05')])
    before = JSON.generate(original)
    alerts = []
    main = nil
    $draft_details_steps = [lambda do |form|
      main = form
      list = field(form, 'Playing windows')
      list.index = 1
      rows, keys = list.options.dup, list.instance_variable_get(:@item_keys).dup
      button(form, action).trigger(:press)
      assert(list.options == rows && list.instance_variable_get(:@item_keys) == keys && list.index == 1, "#{label}: odrzucenie/anulowanie zmieniło rodzica")
      form.accept_button.trigger(:press)
    end, lambda do |dialog|
      if label.start_with?('bad ')
        unavailable = false
        begin
          enter_window(dialog, date: invalid['date'], start: invalid['start'], end_date: invalid['end_date'], finish: invalid['end'])
        rescue TournamentWindowTest::UnavailableChoice
          unavailable = true
        end
        assert(unavailable, "#{label}: błędna wartość jest wybieralna")
        rejected = false
        begin
          GameRoomTournaments::DraftDetails.validate!('windows' => [invalid])
        rescue GameRoomTournaments::DraftDetails::Invalid
          rejected = true
        end
        assert(rejected, "#{label}: backend przyjął dawniej odrzucany format/zakres")
        # Dalszy kontrakt błędu, fokusu i guardów badamy na jawnym braku wyboru.
        enter_window(dialog, date: '', start: '10:15', end_date: '', finish: '12:45')
      else
        enter_window(dialog, date: invalid['date'], start: invalid['start'], end_date: invalid['end_date'], finish: invalid['end'])
      end
      typed = window_state(dialog)
      dialog.index = 3
      dialog.accept_button.trigger(:press)
      missing_part = if label.start_with?('bad ') || label == 'missing start date'
        'Start: year'
      elsif label == 'missing time'
        'Start: hour'
      end
      expected_alert = missing_part ? "Choose a value for #{missing_part}." : WINDOW_ERROR
      expected_focus = missing_part ? dialog.fields.index(field(dialog, missing_part)) : 3
      assert(alerts == [expected_alert] && dialog.instance_variable_get(:@wait) != false, "#{action}/#{label}: przyjęto błędne okno")
      assert(window_state(dialog) == typed && dialog.index == expected_focus, "#{label}: utrata wyborów lub błędny fokus")
      assert(JSON.generate(original) == before && field(main, 'Playing windows').options.size == 2, "#{label}: błąd zmienił dane rodzica")
      dialog.cancel_button.trigger(:press)
      # A delayed Use must not revive an already cancelled dialog.
      enter_window(dialog, date: '2026-10-07', start: '10:15', end_date: '', finish: '12:45')
      dialog.accept_button.trigger(:press)
    end]
    result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { alerts << message }).wait
    assert(result == original && JSON.generate(original) == before && $draft_details_steps.empty?, "#{label}: anulowanie nie zachowało danych")
    puts "PASS #{action}: odrzucenie #{label} bez utraty formularza"
  end
end

original = details_with(Array.new(365) { |index| playing_window((Date.new(2026, 1, 1) + index).iso8601) })
before = JSON.generate(original)
alerts = []
$draft_details_steps = [lambda do |form|
  list = field(form, 'Playing windows')
  button(form, 'Add window').trigger(:press)
  assert(list.options.size == 366 && list.index == 365, 'Nie przyjęto granicznego 366. okna')
  rows, keys = list.options.dup, list.instance_variable_get(:@item_keys).dup
  button(form, 'Add window').trigger(:press)
  assert(list.options == rows && list.instance_variable_get(:@item_keys) == keys, 'Przekroczenie limitu zmieniło listę')
  button(form, 'Edit window').trigger(:press)
  assert(list.options.size == 366 && list.index == 365 && list.options.last == '2027-01-01 10:30 - 2027-01-01 12:45', 'Edycja przy limicie dopisała lub utraciła okno')
  form.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2027-01-01', start: '10:15', end_date: '', finish: '12:45')
  dialog.accept_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2027-01-02', start: '10:15', end_date: '', finish: '12:45')
  typed = window_state(dialog)
  dialog.accept_button.trigger(:press)
  assert(alerts == [WINDOW_ERROR] && dialog.instance_variable_get(:@wait) != false && window_state(dialog) == typed, 'Limit 366 nie zatrzymał dziecka z wpisanym tekstem')
  dialog.cancel_button.trigger(:press)
end, lambda do |dialog|
  TournamentWindowTest.time(dialog, 'Start', '10:30')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { alerts << message }).wait
assert(result['windows'] == original['windows'] + [playing_window('2027-01-01', '10:30')], 'Limit lub edycja zmieniły wcześniejsze okna')
assert(JSON.generate(original) == before && $draft_details_steps.empty?, 'Próba limitu zmieniła wejście lub pominęła dialog')
puts 'PASS limit 366: dodanie na granicy, odrzucenie 367. i edycja bez dopisywania'

PARTICIPANT_ERROR = 'Check the participant names: one per line, no duplicates, at most 256 names of 1-64 characters.'.freeze
{
  'duplicate names' => "Ala\r\nALA",
  'too many names' => (1..257).map { |index| "Person #{index}" }.join("\r\n"),
  'long name' => 'x' * 65,
  'control character' => "Ala\tX"
}.each do |label, invalid_names|
  original = details_with([playing_window])
  before = JSON.generate(original)
  main = nil
  alerts = []
  $draft_details_steps = [lambda do |form|
    main = form
    names = field(form, 'Participants (one name per line; local list)')
    names.text = invalid_names
    field(form, 'Players per match').index = 3
    field(form, 'Multiplayer pairings').index = 1
    form.index = 2
    button(form, 'Add window').trigger(:press)
    form.accept_button.trigger(:press)
    assert(alerts == [PARTICIPANT_ERROR] && form.instance_variable_get(:@wait) != false, "#{label}: błąd uczestników zamknął formularz lub powielił alert")
    assert(names.equal?(field(form, 'Participants (one name per line; local list)')) && names.text == invalid_names && form.index == 2, "#{label}: błąd stracił kontrolkę, tekst lub fokus")
    assert(field(form, 'Players per match').index == 3 && field(form, 'Multiplayer pairings').index == 1 && field(form, 'Playing windows').options.size == 2, "#{label}: błąd stracił pozostałe ustawienia")
    names.text = "Ala\r\nBartek"
    form.accept_button.trigger(:press)
  end, lambda do |dialog|
    enter_window(dialog, date: '2026-10-04', start: '10:15', end_date: '', finish: '12:45')
    dialog.accept_button.trigger(:press)
  end]
  alert = lambda do |message|
    alerts << message
    2.times { trigger_settings_actions(main) } if alerts.size == 1
  end
  result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: alert).wait
  expected = details_with([playing_window, playing_window('2026-10-04')]).merge('participants' => %w[Ala Bartek], 'players_per_match' => 4, 'pairing' => 'all_combinations')
  assert(result == expected && JSON.generate(original) == before, "#{label}: poprawa uczestników zgubiła ustawienia")
  puts "PASS #{label}: poprawa uczestników zachowuje cały formularz i odrzuca reentrant akcje"
end

original = details_with([playing_window, playing_window('2026-10-04')]).merge('participants' => ['Poprzedni'])
before = JSON.generate(original)
old_child = nil
$draft_details_steps = [lambda do |form|
  list = field(form, 'Playing windows')
  list.index = 1
  form.index = 4
  rows, keys = list.options.dup, list.instance_variable_get(:@item_keys).dup
  ['Add window', 'Edit window'].each do |action|
    button(form, action).trigger(:press)
    assert(list.options == rows && list.instance_variable_get(:@item_keys) == keys && list.index == 1 && form.index == 4, 'Anulowanie dziecka zmieniło listę, zaznaczenie lub fokus')
  end
  field(form, 'Participants (one name per line; local list)').text = "Nowy\r\nInny"
  field(form, 'Players per match').index = 2
  field(form, 'Multiplayer pairings').index = 2
  button(form, 'Add window').trigger(:press)
  list.index = 0
  button(form, 'Edit window').trigger(:press)
  button(form, 'Remove window').trigger(:press)
  assert(list.options == ['2026-10-04 10:15 - 2026-10-04 12:45', '2026-10-07 10:15 - 2026-10-07 12:45'], 'Lokalne operacje przed anulowaniem nie zadziałały')
  form.cancel_button.trigger(:press)
  2.times { trigger_settings_actions(form) }
  assert(form.instance_variable_get(:@draft_details_resume_count) == 1, 'Zakończony rodzic zamknął formularz więcej niż raz')
end, lambda do |dialog|
  old_child = dialog
  enter_window(dialog, date: '2026-10-06', start: '10:15', end_date: '', finish: '12:45')
  dialog.cancel_button.trigger(:press)
  2.times { dialog.accept_button.trigger(:press); dialog.cancel_button.trigger(:press) }
  assert(dialog.instance_variable_get(:@draft_details_resume_count) == 1, 'Anulowane dziecko zamknęło formularz ponownie')
end, lambda do |dialog|
  2.times { old_child.accept_button.trigger(:press); old_child.cancel_button.trigger(:press) }
  assert(old_child.instance_variable_get(:@draft_details_resume_count) == 1 && dialog.instance_variable_get(:@wait) != false, 'Stare dziecko zamknęło cudzą operację')
  enter_window(dialog, date: '2026-10-06', start: '10:15', end_date: '', finish: '12:45')
  dialog.cancel_button.trigger(:press)
end, lambda do |dialog|
  enter_window(dialog, date: '2026-10-07', start: '10:15', end_date: '', finish: '12:45')
  dialog.accept_button.trigger(:press)
  2.times { dialog.accept_button.trigger(:press); dialog.cancel_button.trigger(:press) }
  assert(dialog.instance_variable_get(:@draft_details_resume_count) == 1, 'Zapisane dziecko zamknęło formularz ponownie')
end, lambda do |dialog|
  TournamentWindowTest.time(dialog, 'Start', '10:30')
  dialog.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: original, alert: ->(message) { raise message }).wait
assert(result.nil? && JSON.generate(original) == before && $draft_details_steps.empty?, 'Anulowanie ustawień zwróciło dane lub zmieniło oryginalny szkic')
puts 'PASS anulowanie dzieci i całych ustawień: nil, nienaruszony szkic i pojedyncze zamknięcie'

$draft_details_steps = [lambda do |form|
  assert(field(form, 'Participants (one name per line; local list)').text == '' && field(form, 'Playing windows').options.empty?, 'Starszy szkic dostał dane domyślne')
  assert(field(form, 'Players per match').index == 0 && field(form, 'Multiplayer pairings').index == 0, 'Starszy szkic dostał arbitralne wybory')
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftDetailsEditor.new(program: program, details: {}, alert: ->(message) { raise message }).wait
assert(result == GameRoomTournaments::DraftDetails::DEFAULTS, 'Starszy szkic nie zwrócił dokładnie DEFAULTS')
puts 'PASS starszy szkic: puste dane i brak arbitralnych wyborów'
