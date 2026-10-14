# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_public_ui'
require_relative '../support/localization'
require_relative '../../lib/tournaments/public_screen'
GameRoomTestLocalization.use_language('en')
T = TournamentPublicUI
LIST = 'Ongoing tournaments'.freeze
PREVIEW = 'Tournament details'.freeze

def native_screen(snapshot, **options)
  args = T.arguments(snapshot, **options).reject { |key, _value| [:publication, :snapshot].include?(key) }
  GameRoomTournaments::PublicScreen.new(**args)
end

def presentation(header, item = nil)
  [SpeechOutput.calls.last&.first, NVDA.calls.last&.first].each do |value|
    assert(value.to_s.start_with?(header), "Brak natywnego fokusu #{header}: #{value.inspect}")
    assert(value.include?(item), 'Natywny fokus odczytał inny wiersz') if item
  end
end

[13, 32].each do |key|
  driver = TournamentNativeDriver.new
  snapshot = T.snapshot([T.publication, T.publication(22, game: 'three_five_eight')])
  before = Marshal.dump(snapshot)
  calls, messages = [], []
  driver.press(LIST, 40)
  driver.step(LIST, [13])
  driver.press(PREVIEW, 13) { |form| assert(form.accept_button.nil?, 'Drugi Enter może zapisać') }
  driver.step(PREVIEW) { assert(calls.empty?, 'Enter na liście lub szczegółach dołączył') }
  2.times { driver.press(PREVIEW, 9) }
  driver.press(PREVIEW, key) { |form| assert(form.index == 2, 'Tab nie dotarł do Join') }
  driver.step(PREVIEW) do |form|
    assert(calls == [22] && form.index == 2, 'Join nie był jednorazowy lub zgubił fokus')
    presentation('Join tournament')
    assert(T.field(form, 'Status').text.include?('Registration confirmed.'), 'Brak potwierdzenia po nil odczytu')
  end
  driver.step(PREVIEW, [27])
  driver.step(LIST) do |form|
    assert(form.index == 0 && form.fields.first.index == 1, 'Escape nie wrócił do ID/pola')
    presentation(LIST, 'Próba 22')
  end
  driver.step(LIST, [27])
  reads = 0
  native_screen(snapshot, load: -> { reads += 1; reads == 1 ? snapshot : nil },
    join: ->(id) { calls << id; T.record('confirmed', tournament_id: id) }, alert: ->(message) { messages << message }).run
  driver.finish
  assert(Marshal.dump(snapshot) == before && calls == [22], 'Natywne sterowanie zmieniło dane albo ponowiło zapis')
  puts "PASS native Enter listy/dwukrotny Enter/Tab/Join klawiszem #{key}/Escape; pamięciowa mowa i brajl"
end

[0, 4].each do |origin|
  [:escape, :back].each do |close|
    driver = TournamentNativeDriver.new
    snapshot = T.snapshot([T.publication, T.publication(22)])
    parent = nil
    events = []
    exercise = lambda do |form|
      form.accept_button&.press
      T.button(form, 'Refresh').press
      form.cancel_button.press
    end
    driver.press(LIST, 40)
    origin.times { driver.press(LIST, 9) }
    driver.step(LIST, [13]) do |form|
      parent = form
      [:before_focus, :focus].each do |event|
        form.fields[origin].on(event) { events << event; exercise.call(form) }
      end
      driver.on_resume = lambda do |closed|
        if closed.equal?(parent)
          events << :finished
          exercise.call(parent)
        else
          events << :resume
          exercise.call(parent)
          closed.cancel_button.press
          T.button(closed, 'Join tournament').press
          # Pompowanie modalu nie może zastąpić pola/ID rodzica.
          parent.index = 4
          parent.fields.first.index = 0
        end
      end
    end
    if close == :back
      4.times { driver.press(PREVIEW, 9) }
      driver.step(PREVIEW, [13])
    else
      driver.step(PREVIEW, [27])
    end
    driver.step(LIST) do |form|
      assert(form.index == origin && form.fields.first.index == 1, 'Resume/focus zgubił pierwotne pole lub ID')
      assert(events == [:resume, :before_focus, :focus], 'Pominięto chronione natywne odczyty fokusu')
      presentation(origin.zero? ? LIST : 'View tournament', origin.zero? ? 'Próba 22' : nil)
    end
    driver.step(LIST, [27])
    native_screen(snapshot).run
    driver.finish
    assert(events.last == :finished && driver.forms.length == 2, 'Reentry otworzyło modal albo wznowiło zamkniętą listę')
    puts "PASS native busy/finished: origin=#{origin}, close=#{close}, resume/before_focus/focus, ID/mowa/brajl"
  end
end

# Rzeczywiste odświeżanie ListBox po ID, również gdy callback pompuje UI.
driver = TournamentNativeDriver.new
row = T.publication
other = T.publication(22)
initial = T.snapshot([row, other])
changed = T.snapshot([row, other.merge('title' => 'Zmieniony Łukasz')])
reversed = GameRoomTournaments::Publication::Data.freeze_tree(changed.merge('announcements' => changed['announcements'].reverse))
loads = [initial, reversed, nil, T.snapshot([])]
parent = nil
reads = 0
driver.press(LIST, 40)
5.times { driver.press(LIST, 9) }
driver.press(LIST, 13) { |form| parent = form }
driver.step(LIST) do |form|
  assert(form.index == 5 && form.fields.first.index == 0 && form.fields.first.options.first.include?('Zmieniony'), 'Natywny refresh zgubił ID')
  presentation('Refresh')
end
driver.press(LIST, 13)
driver.step(LIST) { |form| assert(form.fields.first.options.first.include?('Zmieniony'), 'nil odczytu usunął listę') }
driver.press(LIST, 13)
driver.step(LIST) { |form| assert(form.fields.first.options.empty?, 'Poprawny pusty odczyt został zignorowany') }
driver.step(LIST, [27])
native_screen(initial, load: lambda do
  reads += 1
  if parent
    parent.accept_button.press
    T.button(parent, 'Refresh').press
    parent.cancel_button.press
    parent.fields.first.index = 1
    parent.index = 4
  end
  loads.shift
end).run
driver.finish
assert(reads == 4, 'Natywny reentry powielił load')
puts 'PASS native refresh: ID mimo zmiany etykiety/kolejności, nil/empty, callback reentry i fokus'

%w[prepared attempted confirmed outside_window conflict].each do |status|
  driver = TournamentNativeDriver.new
  snapshot = T.snapshot
  parent = nil
  joins = 0
  loads = 0
  events = []
  reenter = lambda do
    T.button(parent, 'Join tournament').press
    T.button(parent, 'Refresh').press
    parent.cancel_button.press
  end
  2.times { driver.press(PREVIEW, 9) }
  driver.press(PREVIEW, 32) do |form|
    parent = form
    [:before_focus, :focus].each { |event| form.fields[2].on(event) { events << event; reenter.call } }
  end
  driver.step(PREVIEW) do |form|
    assert(joins == 1 && loads == 1 && events == [:before_focus, :focus], 'Reentry powielił join/load/focus')
    assert(form.index == 2, 'Podgląd nie przywrócił pola Join')
    presentation('Join tournament')
    assert(T.field(form, 'Status').text.include?(status == 'confirmed' ? 'Registration confirmed.' : status == 'outside_window' ? 'outside the allowed window' : status == 'conflict' ? 'Conflict' : 'not confirmed'), 'Status natywny nie zgadza się z dziennikiem')
  end
  driver.step(PREVIEW, [27])
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot,
    join: ->(_) { joins += 1; reenter.call; parent.index = 4; T.record(status) },
    load: -> { loads += 1; reenter.call; nil }, alert: ->(*) { reenter.call })).wait
  driver.finish
  puts "PASS native wynik #{status}, callback/presentation reentry bez retry; brak wyjść urządzeń"
end

GameRoomTestLocalization.use_language('en')

# Ta sama wspólna ścieżka F1/F2/F3, bez własnych skrótów i bez audio.
[LIST, PREVIEW].each do |header|
  driver = TournamentNativeDriver.new
  snapshot = T.snapshot
  volume = []
  program = Object.new
  program.define_singleton_method(:adjust_game_room_volume) { |key, **_options| volume << key }
  driver.step(header) do |form|
    assert(form.game_room_program.equal?(program), 'Form stracił program dla F2/F3')
    [2, 3, -2, -3].each { |key| form.game_room_hotkey_action(key).call }
    form.game_room_hotkey_action(1).call
    assert(volume == [2, 3, -2, -3], 'Pominięto wspólne sterowanie głośnością')
  end
  driver.step('Keyboard shortcuts', [13]) do |form|
    content = form.fields.first.text
    assert(content.include?(T::MODE) && content.include?('F2') && content.include?('F3'), 'F1 ukrywa backend lub wspólne skróty')
  end
  driver.step(header, [27])
  if header == LIST
    native_screen(snapshot, program: program).run
  else
    GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, program: program)).wait
  end
  driver.finish
  puts "PASS native wspólny Form/F1/powrót oraz F2/F3/Shift: #{header}; audio niewłączone"
end

# Pierwszy focus również może dispatchować callback. Chronimy go przed wait.
[LIST, PREVIEW].each do |header|
  driver = TournamentNativeDriver.new
  initial_reads = 0
  joins = 0
  snapshot = T.snapshot
  installed = false
  injected = false
  original_tick = driver.method(:tick)
  driver.define_singleton_method(:tick) do |form|
    original_tick.call(form)
    if !installed && form.is_a?(GameRoomUI::Form) && form.fields.first.header == header
      installed = true
      form.fields.first.on(:before_focus) do
        unless injected
          injected = true
          T.button(form, 'Refresh').press
          T.button(form, 'Join tournament').press if header == PREVIEW
        end
      end
    end
  end
  driver.step(header, [27]) do
    assert(injected && initial_reads == (header == LIST ? 1 : 0) && joins.zero?, 'Pierwszy before_focus wysłał operację przed wait')
  end
  options = { load: -> { initial_reads += 1; snapshot }, join: ->(_) { joins += 1; T.record('attempted') }, alert: ->(*) {} }
  if header == LIST
    native_screen(snapshot, **options).run
  else
    GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, **options)).wait
  end
  driver.finish
end
puts 'PASS native pierwszy before_focus pod busy; przed wait brak callbacków load/join'

# Minimalny RED obu ekranów zbiera obserwacje przed wspólną asercją.
help_observations = []
[LIST, PREVIEW].each do |header|
  driver = TournamentNativeDriver.new
  snapshot = T.snapshot
  parent, calls = nil, []
  driver.step(header) do |form|
    parent = form
    form.game_room_hotkey_action(1).call
  end
  driver.step('Keyboard shortcuts', [13])
  driver.step(header, [27])
  driver.on_resume = lambda do |form|
    next if form.equal?(parent)
    T.button(parent, header == LIST ? 'Refresh' : 'Join tournament').press
  end
  options = { load: -> { calls << [:load]; snapshot },
    join: ->(id) { calls << [:join, id]; nil }, alert: ->(*) {} }
  if header == LIST
    native_screen(snapshot, **options).run
  else
    GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, **options)).wait
  end
  driver.finish
  help_observations << calls
  puts "CHECK F1 resume #{header}: #{calls.inspect}"
end
assert(help_observations == [[[:load]], []], "F1 uruchomiło callback rodzica: #{help_observations.inspect}")

# F1 nie może udostępniać przycisków przykrytego rodzica callbackom hosta.
# Prawdziwe focus/wait/resume; podmieniamy wyłącznie granice zdarzeń w próbie.
[LIST, PREVIEW].each do |header|
  (header==LIST ? (0..6).to_a : (0..4).to_a).each do |origin|
    [13, 27].each do |close_key|
      driver = TournamentNativeDriver.new
      snapshot = T.snapshot([T.publication, T.publication(22)])
      input = Marshal.dump(snapshot)
      parent, screen, help = nil, nil, nil
      calls, events, texts, carets = [], [], [], []
      return_counts, focus_positions = nil, []
      armed = false
      baseline_calls = header == LIST ? [[:load]] : []
      lifecycle = header == LIST ? :run : :wait
      reenter = lambda do |event|
        events << event
        if event.to_s.start_with?('parent_')
          focus_positions << [parent.index, header == LIST ? parent.fields.first.index : nil]
        end
        parent.game_room_hotkey_action(1).call
        screen.public_send(lifecycle)
        # Każdy callback osobno: pierwsza odrzucona akcja nie może maskować następnej.
        if header == LIST
          parent.accept_button.press
        else
          T.button(parent, 'Join tournament').press
        end
        T.button(parent, 'Refresh').press
        parent.cancel_button.press
        assert(calls == baseline_calls, "F1 #{header}/#{origin}/#{close_key}/#{event}: callback rodzica #{calls.inspect}")
        assert(parent.instance_variable_get(:@wait), 'F1 zakończyło czekanie rodzica')
      end
      original_tick = driver.method(:tick)
      driver.define_singleton_method(:tick) do |form|
        original_tick.call(form)
        if form.is_a?(GameRoomUI::Form) && form.fields.first.header == 'Keyboard shortcuts' && help.nil?
          help = form
          [:before_focus, :focus].each do |event|
            form.fields.first.on(event) { reenter.call("help_#{event}".to_sym) }
          end
        end
      end
      driver.on_resume = lambda do |form|
        if form.equal?(help)
          reenter.call(:help_resume)
          # Wznowienie hosta może przesunąć pole/wiersz, ale nie cel użytkownika.
          parent.index = 4
          parent.fields.first.index = 0 if header == LIST
        elsif form.equal?(parent)
          events << :parent_resume
          screen.public_send(lifecycle)
          parent.cancel_button.press
          T.button(parent, 'Refresh').press
        end
      end
      driver.press(header, 40) if header == LIST
      origin.times { driver.press(header, 9) }
      driver.step(header) do |form|
        parent = form
        assert(form.index == origin, 'Niewłaściwe pole przed F1')
        form.fields.grep(EditBox).each do |field|
          field.index, field.check = 3, 8
          texts << [field, field.text.dup]
          carets << [field, field.index, field.check]
        end
        target = form.fields[origin]
        [:before_focus, :focus].each do |event|
          target.on(event) { reenter.call("parent_#{event}".to_sym) if armed }
        end
        original_focus = target.method(:focus)
        target.define_singleton_method(:focus) do |*arguments|
          reenter.call(:parent_control_focus) if armed
          original_focus.call(*arguments)
        end
        armed = true
        form.game_room_hotkey_action(1).call
        armed = false
        assert(form.index == origin, 'F1 zgubiło pole rodzica')
        assert(form.fields.first.index == 1, 'F1 przesunęło ID listy') if header == LIST
        assert(texts.all? { |field, value| field.text == value }, 'F1 zmieniło tekst statusu/szczegółów')
        assert(carets.all? { |field, index, check| [field.index, field.check] == [index, check] }, 'F1 zgubiło kursor/zaznaczenie')
        speech = SpeechOutput.calls.drop(return_counts[0]).map(&:first)
        braille = NVDA.calls.drop(return_counts[1]).map(&:first)
        puts "CHECK pojedynczy F1 #{header}/#{origin}/#{close_key}: #{ {speech: speech.length, braille: braille.length, events: events, positions: focus_positions}.inspect }"
        assert(speech.length == 1 && braille.length == 1, 'F1 musi ogłosić rodzica dokładnie raz w mowie i brajlu')
        expected = [:help_before_focus, :help_focus, :modal, :help_resume,
          :parent_before_focus, :parent_control_focus, :parent_focus]
        assert(events == expected, "F1 pominęło chroniony focus: #{events.inspect}")
        assert(focus_positions == [[origin, header == LIST ? 1 : nil]] * 3, 'F1 zaprezentowało przejściowo inne pole lub ID')
        assert(calls == baseline_calls, 'F1 wysłało operację')
        focus_header = parent.fields[origin].header || parent.fields[origin].label
        (speech + braille).each do |value|
          assert(value.start_with?(focus_header), 'F1 odczytało inne pole rodzica')
          if header == LIST && origin.zero?
            assert(value.include?('Próba 22') && !value.include?('Próba 11'), 'Nawet pierwszy odczyt F1 musi dotyczyć oryginalnego ID')
          end
        end
        presentation(focus_header, header == LIST && origin.zero? ? 'Próba 22' : nil)
        assert(driver.resume_counts.fetch(help) == 1 && !driver.resume_counts.key?(parent), 'F1 nie zamknęło wyłącznie pomocy, dokładnie raz')
      end
      driver.step('Keyboard shortcuts', [close_key]) do |form|
        assert(form.fields.first.text.include?(T::MODE), 'F1 utraciło wspólną treść pomocy')
        form.game_room_hotkey_action(1).call
        reenter.call(:modal)
        return_counts = [SpeechOutput.calls.length, NVDA.calls.length]
      end
      # Dopiero następna świadoma akcja po F1 może uruchomić operację.
      driver.press(header, 13) do |form|
        form.index = header == LIST ? 5 : 2
      end
      driver.step(header) do
        expected = header == LIST ? [[:load], [:load]] : [[:join, 11], [:load]]
        assert(calls == expected, "Po F1 pozostał busy/finished albo zmienił się cel: #{calls.inspect}")
      end
      if header == LIST
        driver.step(header, [13]) { |form| form.index = 4 }
        driver.step(PREVIEW, [27]) do |form|
          assert(form.fields.first.text.include?('Próba 22'), 'View po F1 przesunęło cel')
        end
      end
      driver.step(header, [27])
      options = { load: -> { calls << [:load]; snapshot },
        join: ->(id) { calls << [:join, id]; T.record('confirmed', tournament_id: id) }, alert: ->(*) {} }
      screen = header == LIST ? native_screen(snapshot, **options) : GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, **options))
      screen.public_send(lifecycle)
      driver.finish
      assert(Marshal.dump(snapshot) == input, 'F1 zmieniło dane wejściowe')
      assert(driver.forms.length == (header == LIST ? 3 : 2), 'F1 reentry otworzyło dodatkowy formularz')
      assert(driver.resume_counts.values.all? { |count| count == 1 }, 'F1 lub Back zamknęło formularz wielokrotnie')
      puts "PASS native F1 #{header}: pole=#{origin}, zamknięcie=#{close_key}, firstfocus/resume/focus, ID/tekst/caret, świadoma akcja po pomocy"
    end
  end
end

# Symulacja sposobu wczytania źródeł hosta, NIE budowa ani test gotowej paczki.
%w[public_text public_preview public_screen].each do |name|
  path = File.expand_path("../../lib/tournaments/#{name}.rb", __dir__)
  source = File.binread(path).sub(/\A# encoding: UTF-8\r?\n/, '')
  TOPLEVEL_BINDING.eval(source, path, 2)
end
# Host dodaje własne polskie nazwy ról do tekstów z angielskiego fallbacku.
def p_(context, text)
  return 'Przycisk' if context == 'EAPI_Form' && text == 'Button'
  text
end
%w[en pl].each do |language|
  GameRoomTestLocalization.use_language(language)
  driver = TournamentNativeDriver.new
  snapshot = T.snapshot([T.publication(game: 'rummy', options: { 'elimination' => true, 'score_limit' => 1700 })])
  label = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
  list_header = label.call('Ongoing tournaments')
  preview_header = label.call('Tournament details')
  back_label = label.call('Back')
  driver.step(list_header, [13]) do |form|
    assert(form.fields.first.options.first.encoding == Encoding::UTF_8, 'Binarne etykiety listy nie są UTF8')
    assert(form.game_room_general_help_tips.join.include?(T::MODE), 'Binarna pomoc zgubiła backend')
  end
  driver.step(preview_header) do |form|
    assert(form.fields.first.text.include?('1700') && form.fields.first.text.include?('Łódź'), 'Binarne szczegóły zgubiły nieASCII lub opcje')
    form.fields.each do |field|
      value = field.is_a?(Button) ? field.label : field.text
      assert(value.valid_encoding? && value.encoding == Encoding::UTF_8, 'Binarne pole UI nie jest UTF8')
    end
    assert(back_label == 'Wstecz', 'Nie użyto istniejącego katalogu PL') if language == 'pl'
  end
  4.times { driver.press(preview_header, 9) }
  driver.step(preview_header, [13]) { presentation(back_label) }
  driver.step(list_header) { presentation(list_header, 'Łódź') }
  driver.step(list_header, [27])
  native_screen(snapshot).run
  driver.finish
  puts "PASS native źródła ASCII-8BIT, #{language.upcase}, brakujące EN ze znakami nieASCII i istniejące PL; nie pełne PL"
end

# Nadal źródła binarne; natywne kontrolki z wyjściami wyłącznie pamięciowymi.
GameRoomTestLocalization.use_language('en')
row = T.publication
cached = T.snapshot([row]).fetch('announcements').first
current = T.snapshot([row, row.merge('__id' => 7)], [T.registration(93)])
before = Marshal.dump([cached, current])
assert(current.fetch('announcements').first.fetch('alias_ids') == [7, 11] && current.fetch('members').first.fetch('tournament_id') == 7, 'Brak rzeczywistych aliasów/członkostwa')
driver = TournamentNativeDriver.new
calls, alerts, events = [], [], []
reads = 0
parent = nil
reenter = lambda do
  T.button(parent, 'Join tournament').press
  T.button(parent, 'Refresh').press
  parent.cancel_button.press
end
driver.step(PREVIEW) do |form|
  assert(T.field(form, 'Status').text.include?('Outdated preview'), 'Pierwszy render nie odrzucił starego aliasu z nowym snapshotem')
  assert(calls.empty? && reads.zero?, 'Konstruktor wykonał callback')
  form.fields.each do |field|
    value = field.is_a?(Button) ? field.label : field.text
    assert(value.valid_encoding? && value.encoding == Encoding::UTF_8, 'Fail-closed nie zachował UTF8')
  end
end
2.times { driver.press(PREVIEW, 9) }
driver.press(PREVIEW, 13) do |form|
  parent = form
  [:before_focus, :focus].each { |event| form.fields[2].on(event) { events << event; reenter.call } }
end
driver.step(PREVIEW) do |form|
  assert(calls.empty? && reads.zero? && alerts.length == 1, 'Odmowa Enter uruchomiła Join/Load albo powieliła alert')
  assert(events == [:before_focus, :focus] && form.index == 2, 'Odmowa zgubiła chroniony fokus')
  presentation('Join tournament')
end
driver.press(PREVIEW, 32)
driver.step(PREVIEW) do
  assert(calls.empty? && reads.zero? && alerts.length == 2, 'Spacja lub reentry ominęły fail-closed')
  presentation('Join tournament')
end
driver.press(PREVIEW, 9)
driver.press(PREVIEW, 13)
driver.step(PREVIEW) do |form|
  state = T.field(form, 'Status').text
  assert(reads == 1 && calls.empty? && state.include?('Outdated preview') && state.include?('Refresh failed'), 'nil Refresh odblokował niezgodną parę')
  presentation('Refresh')
end
driver.step(PREVIEW, [27])
preview = GameRoomTournaments::PublicPreview.new(**T.arguments(current, publication: cached,
  join: ->(id) { calls << id; nil }, load: -> { reads += 1; nil },
  alert: ->(message) { alerts << message; reenter.call }))
preview.wait
driver.finish
assert(preview.snapshot.equal?(current) && Marshal.dump([cached, current]) == before, 'Zmieniono snapshot rodzica lub wejścia')
assert(alerts.all? { |message| message.include?('Outdated preview') }, 'Odmowa nie ogłosiła przyczyny')
puts 'PASS native initial alias 11/7: fail-closed przed pierwszym renderem, Enter/spacja/alert/focus reentry, nil Refresh, fokus/mowa/brajl, binarne EN i UTF8'
