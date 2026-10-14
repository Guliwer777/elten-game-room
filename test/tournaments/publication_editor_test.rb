# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_publication_editor'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/publication_editor.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::PublicationEditor), 'Brak PublicationEditor')
T = TournamentPublicationEditorTest
Form.prepend(T::Script)

# RED: otwarcie nie jest datą wybieraną przez organizatora.
$publication_editor_step = lambda do |form|
  assert(form.fields.grep(ListBox).none? { |field| field.header.start_with?('Registration opens:') }, 'Otwarcie nadal ma wybieraki')
  assert(form.fields.grep(EditBox).any? { |field| field.text.include?('Registration opens when you publish.') }, 'Brak informacji o otwarciu przy publikacji')
  form.cancel_button.trigger(:press)
end
GameRoomTournaments::PublicationEditor.new(**T.args).wait

original = T.draft
before = Marshal.dump(original)
mode, actor, zone = 'Local test — this computer only', 'Testowa Żaneta', T::ZONE.dup
editor = GameRoomTournaments::PublicationEditor.new(**T.args(draft: original, mode_label: mode, actor: actor, timezone: zone))
assert(Marshal.dump(original) == before && !original.frozen?, 'Konstruktor zmienił/zamroził źródło')
snapshot = editor.instance_variable_get(:@draft)
assert(snapshot.frozen? && snapshot['game_options'].frozen? && snapshot['participants'].frozen? && snapshot['name'].frozen?, 'Kopia szkicu nie jest głęboko immutable')
assert(snapshot['revision'] == 7 && snapshot['game_options'] == original['game_options'], 'Kopia zgubiła rewizję/ustawienia')
assert_raises(ArgumentError) { GameRoomTournaments::PublicationEditor.new(**T.args(timezone: 'Europe/Warsaw')) }
puts "PIN #{RUBY_DESCRIPTION}; JSON #{JSON::VERSION}"
original['name'].replace('NIE TEN SZKIC')
original['game_options']['bot_delay'] = 9
mode.replace('NIE TEN TRYB'); actor.replace('NIE TEN AKTOR'); zone.replace('Europe/Warsaw')
$publication_editor_step = lambda do |form|
  assert(form.is_a?(GameRoomUI::Form) && form.accept_button.nil?, 'Pominięto Form albo włączono globalne zatwierdzenie')
  summary = form.fields.first
  assert(summary.header == T::HEADER && T.readonly?(summary), 'Brak podsumowania tylko do odczytu')
  assert(summary.text.include?('Zmieniony szkic — Łódź') && summary.text.include?('chess'), 'Nie zachowano kopii nazwy/gry')
  assert(summary.text.include?('Local test — this computer only') && summary.text.include?('Test actor: Testowa Żaneta'), 'Brak stałej jawnej tożsamości testowej')
  assert(summary.text.include?(T::ZONE_NOTICE) && summary.text.include?(T::ZONE), 'Brak opisu lokalnej strefy')
  assert(!summary.text.include?('NIE WYSYŁAJ'), 'Edytor pokazuje lokalny roster jako publikowany')
  assert((T.field(form, T::RULES).flags & EditBox::Flags::MultiLine) != 0, 'Regulamin nie jest multiline')
  %w[closes].each do |kind|
    assert(T.field(form, "Registration #{kind}: minute").options[1] == '00', 'Brak minut 00')
    %w[month day hour].each { |part| assert(T.field(form, "Registration #{kind}: #{part}").index.zero?, 'Samodzielnie wybrano datę/godzinę') }
  end
  form.cancel_button.trigger(:press)
end
assert(editor.wait.nil? && editor.wait.nil?, 'Cancel/reentry zwrócił zapis')
puts 'PASS kopia wejścia, jawny testowy kontekst/strefa, multiline, pola dat, anulowanie'

saved, alerts, converted = [], [], []
record = { 'status' => 'confirmed', 'id' => 'test-record' }.freeze
$publication_editor_step = lambda do |form|
  T.fill(form)
  field = T.field(form, 'Registration closes: minute')
  field.index = 0
  T.button(form).trigger(:press)
  assert(saved.empty? && converted.empty?, 'Nieustalone pole dotarło do konwersji/zapisu')
  assert(alerts == ['Choose a value for Registration closes: minute.'], 'Brak dokładnego alertu brakującego pola')
  assert(form.fields[form.index].equal?(field), 'Walidacja nie przywróciła fokusu')
  field.index = 1
  T.button(form).trigger(:press)
end
editor = GameRoomTournaments::PublicationEditor.new(**T.args(
  convert_time: ->(date, time) { converted << [date, time]; date == '2026-10-01' ? 100 : 200 },
  save: ->(**values) { saved << values; record }, alert: ->(message) { alerts << message }))
assert(editor.wait.equal?(record), 'Confirmed nie zwrócił rekordu dziennika')
assert(converted == [['2026-10-02', '12:00']], 'Konwerter nie dostał cywilnych terminów')
assert(saved == [{ rules: 'Graj uczciwie. Żółć.', registration_opens_at: 100, registration_closes_at: 200, timezone: T::ZONE }], 'Payload ma złe keywordy lub dokłada draft/roster/nick/czas')
assert(saved.first[:rules].frozen? && saved.first[:timezone].frozen?, 'Callback dostał zmienną migawkę tekstu')
puts 'PASS walidacja braku, poprawa i jawny zapis dokładnych keywordów z UTC Integer'

now, clock_calls, saved = 10, [], []
$publication_editor_step = lambda do |form|
  assert(clock_calls.empty?, 'Otwarcie formularza czyta zegar publikacji')
  T.button(form).trigger(:press)
  assert(clock_calls.empty?, 'Niepoprawny formularz czyta zegar publikacji')
  now = 120
  T.fill(form)
  T.button(form).trigger(:press)
end
GameRoomTournaments::PublicationEditor.new(**T.args(clock: -> { clock_calls << now; now },
  convert_time: ->(*) { now = 150; 200 }, save: ->(**values) { saved << values; record }, alert: ->(*) {})).wait
assert(clock_calls == [150] && saved.first[:registration_opens_at] == 150, 'Zegar nie jest świeży PO konwersji i walidacji')
[nil, true, '100', 100.0].each do |wrong|
  $publication_editor_step = ->(form) { T.fill(form); T.button(form).trigger(:press) }
  assert_raises(ArgumentError) { GameRoomTournaments::PublicationEditor.new(**T.args(clock: -> { wrong })).wait }
end
puts 'PASS otwarcie T1, walidacja/opóźnienie, submit T2; błędne typy clock nie przechodzą'


['', " \r\n\t", "\u00a0", 'x' * 16_385, 'ą' * 8193, "a\0b", "a\u007fb", "a\u0085b", "a\u2028b", "a\u2029b", "\xff".b.force_encoding('UTF-8'), 'ż'.b].each do |invalid|
  saved, alerts = [], []
  $publication_editor_step = lambda do |form|
    T.fill(form, rules: invalid)
    rules = T.field(form, T::RULES)
    rules.index, rules.check = 1, 2
    T.button(form).trigger(:press)
    assert(saved.empty? && alerts.length == 1, "Nie odrzucono regulaminu #{invalid.inspect}")
    assert(form.fields[form.index].equal?(rules), 'Brak fokusu na regulaminie')
    assert(rules.text == invalid && [rules.index, rules.check] == [1, 2], 'Walidacja zmieniła tekst/caret')
    rules.text = 'Poprawiony regulamin'
    T.button(form).trigger(:press)
  end
  result = GameRoomTournaments::PublicationEditor.new(**T.args(save: ->(**values) { saved << values; record }, alert: ->(message) { alerts << message })).wait
  assert(result.equal?(record) && saved.length == 1, 'Poprawny regulamin nie odblokował jednej próby')
end
['x' * 16_384, 'ą' * 8192, "Zasady\r\n\tDrugi wiersz\n"].each do |valid|
  captured = nil
  $publication_editor_step = ->(form) { T.fill(form, rules: valid); T.button(form).trigger(:press) }
  GameRoomTournaments::PublicationEditor.new(**T.args(save: ->(**values) { captured = values; record })).wait
  assert(captured[:rules] == valid, 'Granica bajtów lub CR/LF/tab została odrzucona/znormalizowana')
end
puts 'PASS regulamin: whitespace, UTF8, sterujące, granice 16384 bajtów, poprawa bez utraty tekstu/caret'

[[200, 100], [100, 100], [-1, 200], [0, -1], [0, 2**63]].each do |times|
  saves, alerts = [], []
  $publication_editor_step = lambda do |form|
    T.fill(form)
    before = T.document(form)
    T.button(form).trigger(:press)
    assert(saves.empty? && alerts.length == 1, "Niedopuszczalny przedział #{times.inspect} został zapisany")
    assert(T.document(form) == before, 'Zły przedział zmienił dokument')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(clock: -> { times[0] }, convert_time: ->(*) { times[1] },
    save: ->(**values) { saves << values; record }, alert: ->(message) { alerts << message })).wait
end
[:invalid_time, :ambiguous_time, :unsupported_time].each do |code|
  calls, messages, saves = 0, [], []
  $publication_editor_step = lambda do |form|
    T.fill(form)
    before = T.document(form)
    T.button(form).trigger(:press)
    assert(saves.empty? && messages.length == 1 && T.document(form) == before, 'Błąd konwersji zapisał/zmienił formularz')
    assert(form.fields[form.index].header == 'Registration closes: year', 'Błąd czasu wskazał inny termin')
    T.button(form).trigger(:press)
  end
  converter = lambda do |date, _time|
    calls += 1
    raise GameRoomTournaments::PublicationEditor::InvalidTime, code if calls == 1
    date == '2026-10-01' ? 0 : 200
  end
  result = GameRoomTournaments::PublicationEditor.new(**T.args(convert_time: converter, save: ->(**values) { saves << values; record },
    alert: ->(message) { messages << message })).wait
  assert(result.equal?(record) && saves.length == 1, 'Typowany błąd czasu uniemożliwił poprawę')
end
[nil, '100', 1.0, true, [100, nil]].each do |wrong|
  $publication_editor_step = ->(form) { T.fill(form); T.button(form).trigger(:press) }
  assert_raises(ArgumentError) { GameRoomTournaments::PublicationEditor.new(**T.args(convert_time: ->(*) { wrong })).wait }
end
failure = ArgumentError.new('Błąd programu konwertera')
assert_raises(ArgumentError) { GameRoomTournaments::PublicationEditor.new(**T.args(convert_time: ->(*) { raise failure })).wait }
assert_raises(ArgumentError) do
  GameRoomTournaments::PublicationEditor.new(**T.args(convert_time: ->(*) { raise GameRoomTournaments::PublicationEditor::InvalidTime, :unknown })).wait
end
puts 'PASS przedziały UTC, świeże otwarcie i trzy typowane błędy konwersji; błędny typ/błąd programu propaguje'

# Najwcześniejsze okno pochodzi ze snapshotu, nie pozycji w tablicy.
windows = [
  { 'date' => '2026-10-03', 'start' => '20:15', 'end_date' => '2026-10-03', 'end' => '21:00' },
  { 'date' => '2026-10-02', 'start' => '18:30', 'end_date' => '2026-10-02', 'end' => '19:00' }
]
saved, converted = [], []
relative_draft = T.draft.merge('windows' => T.windows)
$publication_editor_step = lambda do |form|
  relative_draft['windows'].clear
  deadline = form.fields.grep(ListBox).find { |field| field.header == 'Registration deadline' }
  assert(deadline, 'Brak listy końca zapisów')
  assert(deadline.index.zero? && deadline.options == ['Specific date and time', '1 hour before the start',
    '2 hours before the start', '3 hours before the start', 'One day (24 hours) before the start'], 'Nieprawidłowe tryby/domyslny wybór')
  T.field(form, T::RULES).text = 'Zasady'
  deadline.index = 1
  deadline.trigger(:move)
  assert(form.hidden_controls == %w[year month day hour minute].map { |part| T.field(form, "Registration closes: #{part}") }, 'Ukryte pola nie odpowiadają trybowi')
  T.button(form).trigger(:press)
end
GameRoomTournaments::PublicationEditor.new(**T.args(draft: relative_draft,
  convert_time: ->(date, time) { converted << [date, time]; 200_000 }, save: ->(**values) { saved << values; record })).wait
assert(converted == [['2026-10-02', '18:30']] && saved.first[:registration_closes_at] == 196_400, 'Względny koniec nie jest UTC minus godzina od najwcześniejszego okna')
puts 'PASS lista końca, względny termin bez ukrytych dat, odwrotna kolejność okien'

# Najpierw pojedyncza brakująca granica: puste okna mają komunikat, nie wyjątek.
messages = []
$publication_editor_step = lambda do |form|
  T.field(form, T::RULES).text = 'Zasady'
  deadline = T.field(form, 'Registration deadline')
  deadline.index = 1
  deadline.trigger(:move)
  T.button(form).trigger(:press)
  assert(messages.one? && messages.first.include?('playing windows'), 'Brak czytelnej odmowy bez okien')
  assert(form.fields[form.index].equal?(deadline), 'Odmowa nie wskazuje końca zapisów')
  form.cancel_button.trigger(:press)
end
GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft, convert_time: ->(*) { raise 'Konwersja bez walidacji okien' },
  clock: -> { raise 'Zegar przed walidacją' }, alert: ->(message) { messages << message })).wait
puts 'PASS brak okien blokuje względny termin przed konwersją i zegarem'

[:invalid_time, :ambiguous_time, :unsupported_time].each do |code|
  messages = []
  $publication_editor_step = lambda do |form|
    T.field(form, T::RULES).text = 'Zasady'
    deadline = T.field(form, 'Registration deadline')
    deadline.index = 4
    deadline.trigger(:move)
    T.button(form).trigger(:press)
    assert(messages.one? && messages.first.include?('first playing window'), 'Błąd okna nie ma jasnego opisu')
    assert(form.fields[form.index].equal?(deadline), 'Błąd okna wskazuje ukrytą datę')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows),
    convert_time: ->(*) { raise GameRoomTournaments::PublicationEditor::InvalidTime, code },
    clock: -> { raise 'Zegar przed walidacją okna' }, alert: ->(message) { messages << message })).wait
end
puts 'PASS nieistniejący/niejednoznaczny/niewspierany początek okna: odmowa bez zegara/zapisu'

# Względny koniec <= świeżego teraz nie może skierować fokusu na ukrytą datę.
[3600, 7200, 10800, 86400].each_with_index do |offset, index|
  [99, 100, 101].each do |deadline_time|
    saved, messages = [], []
    $publication_editor_step = lambda do |form|
      T.field(form, T::RULES).text = 'Zasady'
      selector = T.field(form, 'Registration deadline')
      selector.index = index + 1
      selector.trigger(:move)
      T.button(form).trigger(:press)
      if deadline_time <= 100
        assert(saved.empty? && messages.one?, 'Nie odrzucono końca równego/przed teraz')
        assert(form.fields[form.index].equal?(selector), 'Względna odmowa wskazuje ukryte pole')
        form.cancel_button.trigger(:press)
      else
        assert(saved.one? && saved.first[:registration_closes_at] == deadline_time, 'Błędny offset UTC')
      end
    end
    GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows),
      convert_time: ->(*) { deadline_time + offset }, save: ->(**values) { saved << values; record },
      alert: ->(message) { messages << message })).wait
  end
end
puts 'PASS wszystkie cztery offsety, koniec przed/równy/po świeżym teraz i właściwy fokus'

[-1, 2**63].each do |invalid_start|
  messages, saved = [], []
  $publication_editor_step = lambda do |form|
    T.field(form, T::RULES).text = 'Zasady'
    selector = T.field(form, 'Registration deadline')
    selector.index = 1
    selector.trigger(:move)
    T.button(form).trigger(:press)
    assert(saved.empty? && messages.one?, 'Początek okna spoza zakresu dał legalny pozornie koniec')
    assert(form.fields[form.index].equal?(selector), 'Błędny początek nie wskazuje listy końca')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows),
    convert_time: ->(*) { invalid_start }, save: ->(**values) { saved << values; record }, alert: ->(message) { messages << message })).wait
end
puts 'PASS początek okna musi być poprawnym UTC w zakresie, zanim odejmiemy offset'

[-1, 2**63].each do |invalid_close|
  clocks, messages = [], []
  $publication_editor_step = lambda do |form|
    T.fill(form)
    T.button(form).trigger(:press)
    assert(messages.one? && clocks.empty?, 'Odczytano zegar przed walidacją zakresu końca')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(clock: -> { clocks << 100; 100 },
    convert_time: ->(*) { invalid_close }, alert: ->(message) { messages << message })).wait
end
puts 'PASS niedopuszczalny koniec odrzucony przed pobraniem czasu publikacji'

# Pełny cywilny zakres, nie tylko date/start najwcześniejszego wpisu.
invalid_windows = [nil, {}, 'windows', [nil], [{}], [T.windows.first.reject { |key, _| key == 'end_date' }],
  [T.windows.first.merge('extra' => 1)], [T.windows.first.merge('start' => '25:00')],
  [T.windows.first.merge('date' => '2026-02-30')], [T.windows.first.merge('end' => '19:00')],
  [T.windows.first, T.windows.first], Array.new(367) { T.windows.first }]
invalid_windows.each do |invalid|
  messages = []
  $publication_editor_step = lambda do |form|
    T.field(form, T::RULES).text = 'Zasady'
    selector = T.field(form, 'Registration deadline')
    selector.index = 2
    selector.trigger(:move)
    T.button(form).trigger(:press)
    assert(messages.one? && messages.first.include?('playing windows'), 'Brak walidacji całego kształtu windows')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => invalid),
    convert_time: ->(*) { raise 'Konwersja wadliwych windows' }, alert: ->(message) { messages << message })).wait
end
[nil, '100', true, 100.0, [100]].each do |wrong|
  $publication_editor_step = lambda do |form|
    T.field(form, T::RULES).text = 'Zasady'
    T.field(form, 'Registration deadline').index = 1
    T.button(form).trigger(:press)
  end
  assert_raises(ArgumentError) do
    GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows), convert_time: ->(*) { wrong })).wait
  end
end
[ArgumentError.new('Błąd programu'), GameRoomTournaments::PublicationEditor::InvalidTime.new(:unknown)].each do |failure|
  assert_raises(ArgumentError) do
    GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows), convert_time: ->(*) { raise failure })).wait
  end
end
# Konkretny koniec po początku okna pozostaje dozwolony.
$publication_editor_step = lambda do |form|
  T.fill(form)
  T.field(form, 'Registration closes: day').index = 4
  T.button(form).trigger(:press)
end
saved = []
GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows),
  convert_time: ->(date, time) { assert([date, time] == ['2026-10-04', '12:00'], 'Tryb konkretny konwertuje okno'); 900_000 },
  save: ->(**values) { saved << values; record })).wait
assert(saved.one? && saved.first[:registration_closes_at] == 900_000, 'Dodano zakaz konkretnego końca po początku okna')
puts 'PASS cały kształt windows, błędne typy/program konwertera względnego; konkretny termin nie zależy od początku okna'

[nil, 'prepared', 'attempted', 'conflict', 'outside_window', 'confirmed'].product([0, 1, 4]).each do |status, mode|
  output = status && { 'status' => status, 'id' => 'record' }.freeze
  calls, messages, active = 0, [], nil
  editor = nil
  reenter = lambda do
    T.button(active).trigger(:press)
    active.cancel_button.trigger(:press)
    assert(editor.wait.nil?, 'Reentry wait zwrócił niepotwierdzony rekord') unless status == 'confirmed'
  end
  $publication_editor_step = lambda do |form|
    active = form
    T.fill(form)
    selector = T.field(form, 'Registration deadline')
    selector.index = mode
    selector.trigger(:move)
    before = T.document(form)
    T.button(form).trigger(:press)
    selector.index = mode.zero? ? 4 : 0
    selector.trigger(:move)
    assert(calls == 1 && T.document(form) == before, 'Zapis/spóźniony tryb zmienił dokument albo wykonał się drugi raz')
    if status != 'confirmed'
      assert(T.readonly?(T.field(form, T::RULES)), 'Po próbie regulamin pozostał edytowalny')
      assert(form.fields.grep(EditBox).all? { |field| T.readonly?(field) }, 'Po próbie dokument nie jest readonly')
      assert(form.fields.grep(ListBox).empty?, 'Po próbie można zmienić wybory terminów')
      assert(T.readonly?(T.field(form, 'Status')), 'Status jest edytowalny')
      expected = status == 'conflict' ? 'Conflict' : status == 'outside_window' ? 'outside the allowed window' : 'not confirmed'
      assert(T.field(form, 'Status').text.include?(expected), "Nieprawidłowy status #{status.inspect}")
      3.times { T.button(form).trigger(:press) }
      assert(calls == 1 && T.document(form) == before, 'Ponowne Enter odczytało/zapisało inny snapshot')
      form.cancel_button.trigger(:press)
    end
  end
  editor = GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => windows), convert_time: ->(*) { 200_000 }, save: lambda { |**_values|
    calls += 1
    assert(T.readonly?(T.field(active, T::RULES)), 'Dokument nie został zamknięty PRZED callbackiem')
    reenter.call
    output
  }, alert: ->(message) { messages << message; reenter.call }))
  assert(editor.wait.equal?(status == 'confirmed' ? output : nil), 'wait zwrócił niepotwierdzony rekord')
  assert(calls == 1, 'Drugi zapis po zakończeniu')
end
puts 'PASS każdy status/nil, zapis najwyżej raz, readonly przed callbackiem, reentry save/alert/wait'

[-> { {} }, -> { { 'status' => 'unknown' } }, -> { false }, -> { raise ArgumentError, 'błąd programu save' }].each do |outcome|
  calls = 0
  $publication_editor_step = lambda do |form|
    T.fill(form)
    assert_raises(ArgumentError) { T.button(form).trigger(:press) }
    3.times { T.button(form).trigger(:press) }
    assert(calls == 1, 'Błąd programu pozwolił na drugi save')
    assert(T.readonly?(T.field(form, T::RULES)), 'Błąd programu odblokował dokument')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(save: ->(**_) { calls += 1; outcome.call })).wait
end
puts 'PASS nieznany status/typ i wyjątek save propagują, nigdy nie odblokowują drugiej próby'

# Walidacja publikacji, nie druga lista reguł w formularzu.
[
  [{'windows' => [T.windows.first.merge('end' => '00:00')]}, 'This form has not requested publication. Add or correct the playing windows in the saved draft.'],
  [{'pairing' => 'invalid'}, 'This form has not requested publication. Complete the match settings in the saved draft: tournament format, pairing, rematches and players per match.'],
  [{'name' => ''}, 'This form has not requested publication. The saved draft contains invalid publication data. Correct it in Local tournament drafts.'],
  [{'game_id' => 'missing_game'}, 'This form has not requested publication. The saved draft contains invalid publication data. Correct it in Local tournament drafts.']
].each do |changes, expected|
  alerts, saves = [], []
  $publication_editor_step = lambda do |form|
    T.fill(form)
    T.button(form).trigger(:press)
    assert(alerts == [expected] && T.field(form, 'Status').text == expected, 'Nieprzedstawiony typowany błąd danych')
    assert(saves.empty? && !T.readonly?(T.field(form, T::RULES)), 'Błąd danych zablokował lub wysłał formularz')
    form.cancel_button.trigger(:press)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.args[:draft].merge(changes),
    save: ->(**values) { saves << values }, alert: ->(message) { alerts << message })).wait
end
puts 'PASS preflight: niepoprawne okna/pairing/tytuł/gra mają odmowę danych, nie niepewność'
