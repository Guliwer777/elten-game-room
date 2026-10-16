# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_publication_editor'
require_relative '../support/localization'
require_relative '../../lib/tournaments/publication_editor'
GameRoomTestLocalization.use_language('en')
T = TournamentPublicationEditorTest
H = T::HEADER

# Wszystkie odczyty mowy/brajla trafiają wyłącznie do pamięci.
def presentation(header)
  [SpeechOutput.calls.last&.first, NVDA.calls.last&.first].each do |message|
    assert(message.to_s.start_with?(header), "Brak natywnego fokusu #{header}: #{message.inspect}")
  end
end

[13, 32].each do |key|
  driver = TournamentNativeDriver.new
  saved, converted = [], []
  record = { 'status' => 'confirmed', 'id' => 'native-record' }.freeze
  driver.press(H, 9)
  driver.press(H, 13) do |form|
    assert(form.index == 1 && form.accept_button.nil?, 'Tab/globalny accept')
    T.field(form, T::RULES).set_text('AB')
    T.field(form, T::RULES).index = T.field(form, T::RULES).check = 1
  end
  driver.step(H) do |form|
    assert(T.field(form, T::RULES).text == "A\r\nB" && saved.empty?, 'Enter regulaminu nie dodał newline albo wysłał')
  end
  3.times { driver.press(H, 9) }
  # Wybór dat/godzin wyłącznie prawdziwymi klawiszami hosta, minuty pomijane.
  [39, 40, 39, 40, 39, 40, 39].each { |arrow| driver.press(H, arrow) }
  [37, 38, 40, 39].each { |arrow| driver.press(H, arrow) }
  driver.press(H, 9)
  driver.step(H, [16, 9])
  driver.step(H)
  driver.step(H) do |form|
    assert(form.fields[form.index].equal?(T.field(form, 'Registration closes: minute')), 'Strzałki/Tab/Shift+Tab nie dotarły do minut zamknięcia')
    %w[closes].each do |kind|
      assert(T.field(form, "Registration #{kind}: minute").index == 1, 'Nie zachowano domyślnych minut 00')
    end
  end
  2.times { driver.press(H, 9) }
  driver.step(H, [key]) { |form| assert(form.fields[form.index].equal?(T.button(form)), 'Tab nie dotarł do Publikuj') }
  editor = GameRoomTournaments::PublicationEditor.new(**T.args(convert_time: ->(date, time) { converted << [date, time]; 86_400 },
    save: ->(**values) { saved << values; record }))
  assert(editor.wait.equal?(record), 'Confirmed nie zwrócił tego samego rekordu')
  driver.finish
  assert(saved.length == 1 && saved.first[:rules] == "A\r\nB", 'Jedno naciśnięcie wysłało więcej niż raz')
  assert(converted.all? { |date, time| date.match?(/\A\d{4}-01-0[12]\z/) && time == '00:00' }, 'Konwerter nie otrzymał wyborów strzałek')
  puts "PASS native Tab/strzałki/minuty00/Enter-newline/Publish #{key}/UTC Integer"
end

%w[closes].product(%w[year month day hour minute]).each do |kind, part|
  driver = TournamentNativeDriver.new
  alerts, before, rules_cursor = [], nil, nil
  header = "Registration #{kind}: #{part}"
  editor = nil
  reentry = ->(form) { T.button(form).press; form.cancel_button.press; editor.wait }
  driver.step(H) do |form|
    T.fill(form)
    missing = T.field(form, header)
    missing.index = 0
    before = T.document(form)
    rules = T.field(form, T::RULES)
    rules.index, rules.check = 2, 4
    rules_cursor = [rules.index, rules.check]
    [:before_focus, :focus].each { |event| missing.on(event) { reentry.call(form) } }
    form.index = form.fields.index(T.button(form))
  end
  driver.press(H, 13)
  driver.step(H, [27]) do |form|
    assert(alerts == ["Choose a value for #{header}."], 'Brak dokładnego alertu')
    assert(form.fields[form.index].header == header, 'Niewłaściwe nieustalone pole')
    presentation(header)
    rules = T.field(form, T::RULES)
    assert(T.document(form) == before && [rules.index, rules.check] == rules_cursor, 'Walidacja zmieniła wybory/tekst/caret')
  end
  editor = GameRoomTournaments::PublicationEditor.new(**T.args(alert: ->(message) { alerts << message; reentry.call(driver.forms.last) }))
  assert(editor.wait.nil?, 'Escape nie zwrócił nil')
  driver.finish
end
puts 'PASS native każde z 5 nieustalonych pól: dokładny alert, fokus/mowa/brajl, reentry, tekst/caret'

[nil, 'prepared', 'attempted', 'conflict', 'outside_window', 'confirmed'].product([0, 1, 2, 3, 4]).each do |status, mode|
  driver = TournamentNativeDriver.new
  active, editor, before, rules, cursor, selector = nil, nil, nil, nil, nil, nil
  calls, events, messages = 0, [], []
  record = status && { 'status' => status, 'id' => 'native-operation' }.freeze
  reenter = lambda do
    T.button(active).press
    active.cancel_button.press
    editor.wait
  end
  driver.on_resume = lambda do |form|
    assert(editor.instance_variable_get(:@finished) && editor.instance_variable_get(:@busy), 'Resume przed finished albo poza busy')
    events << :resume
    reenter.call
  end
  driver.step(H) do |form|
    active = form
    T.fill(form)
    selector = T.field(form, 'Registration deadline')
    selector.index = mode
    selector.trigger(:move)
    rules = T.field(form, T::RULES)
    rules.index, rules.check = 2, 4
    cursor = [rules.index, rules.check]
    before = T.document(form)
    [:before_focus, :focus].each { |event| T.field(form, 'Status').on(event) { events << event; reenter.call } }
    form.index = form.fields.index(T.button(form))
  end
  if status == 'confirmed'
    driver.step(H, [13])
  else
    driver.press(H, 32)
    driver.step(H) do |form|
      hidden = form.instance_variable_get(:@hidden).dup
      selector.index = mode.zero? ? 4 : 0
      selector.trigger(:move)
      assert(form.instance_variable_get(:@hidden) == hidden, 'Spóźniony tryb odblokował ukryte pola')
      assert(calls == 1 && T.document(form) == before && [rules.index, rules.check] == cursor, 'Próba zmieniła snapshot/kursor')
      assert(form.fields[form.index].equal?(T.field(form, 'Status')) && events == [:before_focus, :focus], 'Brak chronionego natywnego fokusu statusu')
      presentation('Status')
      assert(form.fields.grep(ListBox).empty? && T.readonly?(rules), 'Próba nie zamknęła edycji')
      form.index = 1
    end
    driver.press(H, 13)
    driver.press(H, 46)
    driver.step(H) do |form|
      assert(T.document(form) == before && calls == 1, 'Enter/Delete zmienił readonly lub wysłał drugi raz')
      form.index = form.fields.index(T.button(form))
    end
    driver.press(H, 13)
    driver.press(H, 32)
    driver.step(H, [27]) { |form| assert(calls == 1 && T.document(form) == before, 'Ponowna publikacja zmieniła próbę') }
  end
  editor = GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => T.windows), clock: -> { reenter.call; 100 }, convert_time: lambda { |_date, _time|
    reenter.call
    200_000
  }, save: lambda { |**_values|
    calls += 1
    assert(T.readonly?(rules), 'Callback widzi edytowalny dokument')
    reenter.call
    active.index = active.fields.index(active.cancel_button)
    record
  }, alert: ->(message) { messages << message; reenter.call }))
  assert(editor.wait.equal?(status == 'confirmed' ? record : nil), 'Nieprawidłowy wynik wait')
  driver.finish
  assert(calls == 1 && events.last == :resume, 'Save/resume został powielony')
end
puts 'PASS native wszystkie statusy/nil, readonly, ponowne Enter/spacja, reentry konwertera/save/alert/focus/resume'

# Ochrona początkowego fokusu także przed reentry całego wait.
driver = TournamentNativeDriver.new
editor = nil
injected = false
original_tick = driver.method(:tick)
driver.define_singleton_method(:tick) do |form|
  original_tick.call(form)
  next unless !injected && form.is_a?(GameRoomUI::Form) && form.fields.first.header == H
  injected = true
  [:before_focus, :focus].each do |event|
    form.fields.first.on(event) do
      T.button(form).press
      form.cancel_button.press
      editor.wait
    end
  end
end
driver.step(H, [27]) { assert(injected, 'Nie dostarczono pierwszego fokusu') }
editor = GameRoomTournaments::PublicationEditor.new(**T.args)
assert(editor.wait.nil?, 'Pierwszy fokus zapisał/anulował za wcześnie')
driver.finish
puts 'PASS native first focus/before_focus i wait reentry pod busy'

# Wspólne F1 otwiera modal; przez cały jego resume i powrót trwa guard.
driver = TournamentNativeDriver.new
parent, editor, return_counts = nil, nil, nil
volume = []
program = Object.new
program.define_singleton_method(:adjust_game_room_volume) { |key, **_options| volume << key }
driver.step(H) do |form|
  parent = form
  T.fill(form)
  form.index = 1
  rules = T.field(form, T::RULES)
  rules.index, rules.check = 2, 4
  [:before_focus, :focus].each do |event|
    rules.on(event) { T.button(form).press; form.cancel_button.press; editor.wait }
  end
  form.game_room_hotkey_action(1).call
  assert(form.index == 1 && [rules.index, rules.check] == [2, 4], 'F1 zgubił pole/kursor')
  assert(SpeechOutput.calls.drop(return_counts[0]).length == 1 && NVDA.calls.drop(return_counts[1]).length == 1, 'F1 powtórzył odczyt rodzica')
  [2, 3, -2, -3].each { |key| form.game_room_hotkey_action(key).call }
end
driver.step('Keyboard shortcuts', [13]) do |form|
  content = form.fields.first.text
  assert(content.include?('first playing window') && content.include?('24 hours') && content.include?('Registration opens when you publish.') && content.include?(T::ZONE_NOTICE), 'F1 ukrywa znaczenie dat/strefy')
  assert(content.include?('Test actor: Testowa Żaneta'), 'F1 zgubiło aktora testowego')
end
driver.step(H, [27])
driver.on_resume = lambda do |form|
  next if form.equal?(parent)
  T.button(parent).press
  parent.cancel_button.press
  editor.wait
  parent.index = parent.fields.index(parent.cancel_button)
  return_counts = [SpeechOutput.calls.length, NVDA.calls.length]
end
editor = GameRoomTournaments::PublicationEditor.new(**T.args(program: program))
assert(editor.wait.nil?, 'F1 wysłało formularz')
driver.finish
assert(volume == [2, 3, -2, -3], 'Pominięto wspólne F2/F3')
puts 'PASS native wspólne F1, busy przez modal/resume, kursor; F2/F3 bez audio'

# Zmiana miesiąca usuwa niedostępny dzień i również woła alert WindowFields.
driver = TournamentNativeDriver.new
editor = nil
messages = []
driver.step(H) do |form|
  T.fill(form)
  month = T.field(form, 'Registration closes: month')
  month.index = 1
  month.trigger(:move)
  T.field(form, 'Registration closes: day').index = 31
  form.index = form.fields.index(T.field(form, 'Registration closes: month'))
end
driver.press(H, 40)
driver.step(H, [27]) do |form|
  assert(messages.length == 1 && T.field(form, 'Registration closes: day').index.zero?, 'Zmiana miesiąca zgubiła komunikat lub dzień')
  assert(form.fields[form.index].equal?(T.field(form, 'Registration closes: month')), 'Powrót z alertu miesiąca zgubił pole')
  presentation('Registration closes: month')
end
editor = GameRoomTournaments::PublicationEditor.new(**T.args(alert: lambda { |message|
  messages << message
  assert(editor.instance_variable_get(:@busy), 'Alert WindowFields poza busy')
  form = driver.forms.last
  T.button(form).press
  form.cancel_button.press
  editor.wait
}))
editor.wait
driver.finish
puts 'PASS native zmiana miesiąca: notice WindowFields i powrót fokusu pod busy'

# Zmiana trybu przez prawdziwe strzałki, Tab i Shift+Tab, bez przebudowy/mowy.
[false, true].each do |submit|
  driver = TournamentNativeDriver.new
  original_fields, chosen, selector, now, clocks, saved, counts = nil, nil, nil, 10, [], [], nil
  driver.step(H) do |form|
    original_fields = form.fields.dup
    assert(clocks.empty?, 'Budowa formularza pobrała czas publikacji')
    form.index = form.fields.index(T.button(form))
  end
  driver.press(H, 13)
  driver.step(H) do |form|
    assert(clocks.empty?, 'Walidacja braków odczytała zegar')
    T.fill(form)
    chosen = T.document(form)
    selector = T.field(form, 'Registration deadline')
    form.index = form.fields.index(selector)
  end
  driver.press(H, 40)
  driver.press(H, 9)
  driver.step(H) { |form| assert(form.fields[form.index].equal?(T.field(form, 'Status')), 'Tab wszedł w ukrytą datę') }
  driver.step(H, [16, 9])
  driver.step(H) { |form| assert(form.fields[form.index].equal?(selector), 'Shift+Tab wszedł w ukrytą datę') }
  driver.press(H, 40)
  driver.press(H, 38)
  driver.press(H, 38)
  driver.step(H) do |form|
    assert(T.document(form) == chosen && form.fields == original_fields, 'Przełączenie zgubiło datę lub przebudowało formularz')
  end
  driver.press(H, 9)
  driver.step(H) { |form| assert(form.fields[form.index].equal?(T.field(form, 'Registration closes: year')), 'Tab nie wrócił do konkretnych dat') }
  driver.step(H, [16, 9])
  driver.step(H)
  driver.press(H, 40)
  driver.step(H) do |form|
    assert(form.fields[form.index].equal?(selector), 'Względny tryb wyrwał fokus')
    form.game_room_hotkey_action(1).call
    assert(clocks.empty?, 'F1 odczytało czas publikacji')
    assert(SpeechOutput.calls.drop(counts[0]).length == 1 && NVDA.calls.drop(counts[1]).length == 1, 'Powrót F1 nie ma pojedynczego odczytu')
    assert(form.fields[form.index].equal?(selector), 'F1 zmieniło pole')
    now = 150
    form.index = form.fields.index(T.button(form)) if submit
  end
  driver.step('Keyboard shortcuts', [27]) do |form|
    assert(form.fields.first.text.include?('24 hours'), 'Pomoc nie wyjaśnia doby')
    counts = [SpeechOutput.calls.length, NVDA.calls.length]
  end
  driver.step(H, [submit ? 13 : 27])
  result = GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.draft.merge('windows' => T.windows),
    clock: -> { clocks << now; now }, convert_time: ->(*) { 10_000 },
    save: ->(**values) { saved << values; {'status' => 'confirmed'} }, alert: ->(*) {})).wait
  driver.finish
  if submit
    assert(clocks == [150] && saved.one? && saved.first[:registration_opens_at] == 150 && saved.first[:registration_closes_at] == 6400, 'T1/walidacja/F1/T2 nie używa świeżego czasu')
  else
    assert(result.nil? && saved.empty? && clocks.empty?, 'Escape w trybie względnym zapisał lub odczytał zegar')
  end
end
puts 'PASS native przełączenia, zachowanie wpisów/kontrolek, Tab/ShiftTab, T1/walidacja/F1/T2 oraz Escape'

# Binarne źródło w stylu loadera ELTEN-a; to nie jest budowanie paczki.
GameRoomTournaments.send(:remove_const, :PublicationEditor)
path = File.expand_path('../../lib/tournaments/publication_editor.rb', __dir__)
TOPLEVEL_BINDING.eval(File.binread(path).sub(/\A# encoding: UTF-8\r?\n/, ''), path, 2)
def p_(context, text)
  return 'Przycisk' if context == 'EAPI_Form' && text == 'Button'
  text
end
%w[en pl].each do |language|
  GameRoomTestLocalization.use_language(language)
  label = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
  header = label.call(H)
  alerts = []
  driver = TournamentNativeDriver.new
  driver.step(header) do |form|
    assert(form.fields.first.text.include?('Łódź') && form.fields.first.text.include?(T::ZONE), 'Binarna kopia zgubiła tekst/strefę')
    form.fields.each_with_index do |field, index|
      values = field.is_a?(Button) ? [field.label] : [field.header, *(field.is_a?(ListBox) ? field.options : [field.text])]
      assert(values.all? { |value| value.valid_encoding? && value.encoding == Encoding::UTF_8 }, 'Binarna etykieta/wartość nie jest UTF8')
      form.index = index
      form.focus
    end
    assert(form.cancel_button.label == 'Anuluj', 'Nie użyto istniejącego tłumaczenia PL') if language == 'pl'
    form.index = form.fields.index(T.button(form, label.call(T::PUBLISH)))
  end
  driver.press(header, 13)
  driver.step(header, [27]) do |form|
    missing = T.field(form, label.call('Registration closes: month'))
    assert(alerts == [format(label.call('Choose a value for %{field}.'), field: missing.header)], 'Binarna interpolacja zgubiła etykietę')
    assert(form.fields[form.index].equal?(T.field(form, label.call('Registration closes: month'))), 'Binarna walidacja nie wskazała miesiąca')
    presentation(missing.header)
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(alert: ->(message) { alerts << message })).wait
  driver.finish
  puts "PASS native źródło ASCII-8BIT, #{language.upcase}, polska rola hosta, wszystkie etykiety UTF8; nie pełne PL"
end
GameRoomTestLocalization.use_language('en')

# Nowa odmowa również z binarnych źródeł. PL używa bieżącego katalogu;
# brak nowych tłumaczeń kontrolują osobne obowiązkowe testy lokalizacji.
%w[en pl].each do |language|
  GameRoomTestLocalization.use_language(language)
  label = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
  expected = label.call('This form has not requested publication. Complete the match settings in the saved draft: tournament format, pairing, rematches and players per match.')
  driver = TournamentNativeDriver.new
  messages = []
  driver.step(label.call(H)) do |form|
    T.field(form, label.call(T::RULES)).set_text('Regulamin — Żółć')
    %w[year month day hour minute].zip([2026, 10, 2, 12, 0]).each do |part, value|
      field = T.field(form, label.call("Registration closes: #{part}"))
      field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)) || raise('Brak wyboru daty')
      field.trigger(:move)
    end
    form.index = form.fields.index(T.button(form, label.call(T::PUBLISH)))
    T.button(form, label.call(T::PUBLISH)).press
    status = T.field(form, label.call('Status'))
    assert(status.text == expected && messages == [expected], 'Binarna odmowa straciła dokładny Status')
    assert(status.text.encoding == Encoding::UTF_8 && status.text.valid_encoding?, 'Odmowa nie jest UTF8')
    form.index = form.fields.index(status)
    form.focus
    presentation(status.header)
    form.cancel_button.press
  end
  GameRoomTournaments::PublicationEditor.new(**T.args(draft: T.args[:draft].merge('pairing' => nil),
    alert: ->(message) { messages << message })).wait
  driver.finish
  puts "PASS native preflight ASCII-8BIT/#{language}: dokładny Status/alert UTF8 i natywny fokus"
end
GameRoomTestLocalization.use_language('en')
