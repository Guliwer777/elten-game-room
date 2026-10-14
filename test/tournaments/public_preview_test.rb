# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/public_preview.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::PublicPreview), 'Brakuje osobnego podglądu opublikowanego turnieju')
Form.prepend(TournamentPublicUI::Script)
T = TournamentPublicUI

snapshot = T.snapshot([T.publication, T.publication(22)], [T.registration(31), T.registration(32, tournament_id: 22, user: 'Obcy')])
before = Marshal.dump(snapshot)
T.script(lambda do |form|
  details = T.field(form, 'Tournament details')
  assert(details.is_a?(GameRoomUI::HelpText), 'Szczegóły nie używają wspólnego tekstu pomocy')
  assert(details.instance_variable_get(:@type) & EditBox::Flags::ReadOnly != 0, 'Podgląd jest edytowalny')
  %w[Łódź Chess Łukasz Żółć Europe/Warsaw].each { |word| assert(details.text.include?(word), "Brakuje #{word}") }
  [Time.at(100).getlocal.strftime('%Y-%m-%d %H:%M:%S %:z'), Time.at(200).getlocal.strftime('%Y-%m-%d %H:%M:%S %:z'), '2026-10-15 18:00', '21:00', T::MODE, T::ACTOR].each do |word|
    assert(details.text.include?(word), "Brakuje #{word}")
  end
  assert(!details.text.include?('Obcy') && !details.text.include?('NIE POKAZUJ ROSTERU'), 'Podgląd ujawnia obcy skład lub ręczny roster')
  assert(!details.text.include?('settings_json') && !details.text.include?('{"'), 'Surowy JSON zamiast opisu')
  assert(form.accept_button.nil?, 'Join nie może być globalnym Enter')
  assert(form.game_room_general_help_tips.join.include?(T::MODE), 'Pomoc ukrywa backend')
  form.cancel_button.trigger(:press)
end) { GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot)).wait }
assert(Marshal.dump(snapshot) == before, 'Podgląd zmienił frozen snapshot')
puts 'PASS read-only: rzeczywista gra, regulamin, UTC, cywilna strefa, własny skład i brak globalnego Join'

variants = [['chess', {}], ['three_five_eight', {}], ['rummy', { 'elimination' => true, 'score_limit' => 1700 }]]
quiz = GameRoomGames::CATALOG.build('quiz')
languages = quiz.effective_option_definitions({}).find { |definition| definition.key == GameRoomContent::LANGUAGE_OPTION_KEY }.choices
languages.each do |language|
  selected = { GameRoomContent::LANGUAGE_OPTION_KEY => language.value }
  sets = quiz.effective_option_definitions(selected).find { |definition| definition.key == GameRoomContent::SET_OPTION_KEY }.choices
  variants << ['quiz', selected.merge(GameRoomContent::SET_OPTION_KEY => sets.last.value)]
end
variants.each do |game_id, input_options|
  snapshot = T.snapshot([T.publication(game: game_id, options: input_options, 'format' => 'groups_knockout', 'rematch' => true, 'pairing' => 'balanced_cycle')])
  game = GameRoomGames::CATALOG.build(game_id)
  options = JSON.parse(snapshot['announcements'].first['settings_json']).fetch('game_options')
  before = Marshal.dump(snapshot)
  T.script(lambda do |form|
    content = T.field(form, 'Tournament details').text
    assert(content.include?('Groups and knockout') && content.include?('Return matches: Yes') && content.include?('Rotating compositions'), 'Pominięto wariant turnieju')
    game.effective_option_definitions(options).each do |definition|
      label = GameRoomContent.utf8(definition.summary_label || definition.label)
      unless game.option_visible?(definition, options, normalize: false)
        assert(!content.include?(label + ': '), 'Pokazano nieaktywną opcję zależną')
        next
      end
      value = options[definition.key.to_s]
      expected = case definition.kind.to_sym
      when :boolean then value ? 'Yes' : 'No'
      when :choice then definition.choices.find { |choice| choice.value.to_s == value.to_s }.label
      when :multiple_choice
        labels = definition.choices.each_with_index.filter_map { |choice, index| choice.label if (value & (1 << index)) != 0 }
        labels.empty? ? 'None' : labels.join(', ')
      else
        definition.summary_unit == :seconds ? "#{value} seconds" : value.to_s
      end
      assert(content.include?("#{label}: #{expected}"), "Brak etykiet opcji #{game_id}/#{definition.key}: #{expected}")
    end
    form.cancel_button.trigger(:press)
  end) { GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot)).wait }
  assert(Marshal.dump(snapshot) == before, 'Formatowanie opcji zmieniło wejście')
end
puts 'PASS rzeczywiste definicje opcji: chess, 3-5-8, remik 1700/eliminacja, Quiz zależne języki i zestawy'

snapshot = T.snapshot
expected = { 'confirmed' => 'Registration confirmed.', 'prepared' => 'Registration not confirmed.',
  'attempted' => 'Registration not confirmed.', 'outside_window' => 'Registration outside the allowed window.',
  'conflict' => 'Conflict — registration was not sent again.', nil => 'Registration not confirmed.' }
expected.each do |status, message|
  result = status && T.record(status)
  joins, messages, loads = [], [], 0
  T.script(lambda do |form|
    join = T.button(form, 'Join tournament')
    form.index = form.fields.index(join)
    join.trigger(:press)
    assert(joins == [11], 'Join nie przekazał dokładnie ID wiersza')
    state = T.field(form, 'Status').text
    assert(state.include?(message), "Nieprawidłowy wynik #{status.inspect}: #{state}")
    assert(messages.any? { |item| item.include?(message) } || status.nil?, 'Nie ogłoszono wyniku operacji')
    assert(form.fields[form.index].equal?(join), 'Po dołączeniu utracono fokus przycisku')
    assert(T.field(form, 'Tournament details').text.include?('Accepted participants: 0'), 'UI wymyśliło członkostwo z wyniku dziennika')
    assert(loads == 1, 'Nie wykonano świeżego odczytu po próbie')
    join.trigger(:press)
    assert(joins == [11], 'Podgląd wysłał ponownie po rozstrzygnięciu lub niepewności')
    form.cancel_button.trigger(:press)
  end) do
    GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, load: -> { loads += 1; nil },
      join: ->(id) { joins << id; result }, alert: ->(value) { messages << value })).wait
  end
end
puts 'PASS każdy status i nil: ID zamiast indeksu, bez pozornego sukcesu, confirmed przetrwał nil odczytu, brak ponownej wysyłki'

member_snapshot = T.snapshot([T.publication], [T.registration(51, user: 'ŻANETA')])
T.script(lambda do |form|
  assert(T.field(form, 'Status').text.include?('Already registered.'), 'Nie rozpoznano członkostwa bez wielkości liter')
  T.button(form, 'Join tournament').trigger(:press)
  form.cancel_button.trigger(:press)
end) { GameRoomTournaments::PublicPreview.new(**T.arguments(member_snapshot, alert: ->(*) {})).wait }
puts 'PASS już zapisany według zaakceptowanego snapshotu, case-insensitive'

[[], [T.publication.merge('rules' => 'Sprzeczny regulamin'), T.publication]].each do |rows|
  initial = T.snapshot
  gone = T.snapshot(rows)
  loads = [nil, gone]
  dialog = nil
  T.script(lambda do |form|
    description = T.field(form, 'Tournament details').text.dup
    T.button(form, 'Refresh').trigger(:press)
    assert(T.field(form, 'Tournament details').text == description && dialog.snapshot.equal?(initial), 'nil wyczyścił szczegóły')
    T.button(form, 'Refresh').trigger(:press)
    assert(T.field(form, 'Status').text.include?('Outdated preview'), 'Brak stanu nieaktualności po usunięciu/konflikcie')
    assert(T.field(form, 'Tournament details').text == description, 'Nieaktualny podgląd zniknął')
    T.button(form, 'Join tournament').trigger(:press)
    form.cancel_button.trigger(:press)
  end) do
    dialog = GameRoomTournaments::PublicPreview.new(**T.arguments(initial, load: -> { loads.shift }, alert: ->(*) {}))
    dialog.wait
  end
  assert(dialog.snapshot.equal?(gone), 'Rodzic nie otrzyma nowego snapshotu')
end
puts 'PASS oddzielny Refresh bez Join, nil nie usuwa, zniknięcie/konflikt zatrzymuje stare Join'

initial = T.snapshot
fresh = T.snapshot([T.publication], [T.registration(81)])
T.script(lambda do |form|
  T.button(form, 'Join tournament').trigger(:press)
  assert(T.field(form, 'Status').text.include?('Registration confirmed.') && T.field(form, 'Status').text.include?('Already registered.'), 'Wynik operacji zniknął po świeżym członkostwie')
  assert(T.field(form, 'Tournament details').text.include?('Accepted participants: 1'), 'Nie pokazano odczytanego członkostwa')
  form.cancel_button.trigger(:press)
end) do
  GameRoomTournaments::PublicPreview.new(**T.arguments(initial, load: -> { fresh }, join: ->(_) { T.record('confirmed') }, alert: ->(*) {})).wait
end
puts 'PASS potwierdzenie i świeży zaakceptowany skład są osobnymi źródłami informacji'

[true, false].each do |joining|
  instance = parent = nil
  calls = []
  reenter = lambda do |move = false|
    instance.wait
    T.button(parent, 'Join tournament').trigger(:press)
    T.button(parent, 'Refresh').trigger(:press)
    parent.cancel_button.trigger(:press)
    parent.index = 4 if move
    assert(parent.instance_variable_get(:@wait) != false, 'Reentry zamknęło podgląd')
  end
  T.script(lambda do |form|
    parent = form
    action = T.button(form, joining ? 'Join tournament' : 'Refresh')
    form.index = form.fields.index(action)
    [:before_focus, :focus].each { |event| action.on(event) { reenter.call } }
    action.trigger(:press)
    assert(calls == (joining ? [:join, :load] : [:load]), 'Reentry powieliło callbacki')
    assert(form.index == (joining ? 2 : 3), 'Callback zgubił pierwotne pole')
    # finished przed resume, także gdy resume natychmiast pompuje callbacki.
    resume = form.method(:resume)
    resumes = 0
    form.define_singleton_method(:resume) do
      resumes += 1
      resume.call
      cancel_button.trigger(:press)
      T.button(self, 'Refresh').trigger(:press)
      T.button(self, 'Join tournament').trigger(:press)
    end
    form.cancel_button.trigger(:press)
    assert(resumes == 1, 'finished ustawiono dopiero po resume')
  end) do
    instance = GameRoomTournaments::PublicPreview.new(**T.arguments(initial,
      join: ->(_) { calls << :join; reenter.call(true); T.record('attempted') },
      load: -> { calls << :load; reenter.call(true); nil }, alert: ->(*) { reenter.call }))
    instance.wait
  end
end
puts 'PASS reentry callbacków load/join/alert, wait, resume i przywracania fokusu'

['unconfirmed', 'failed', '', nil].each do |unknown|
  T.script(lambda do |form|
    error = assert_raises(ArgumentError) { T.button(form, 'Join tournament').trigger(:press) }
    assert(error.message.include?('Unexpected tournament join status'), 'Nieznany status ukryto jako błąd transportu')
    form.cancel_button.trigger(:press)
  end) do
    GameRoomTournaments::PublicPreview.new(**T.arguments(initial, join: ->(_) { T.record(unknown) })).wait
  end
end
[ArgumentError.new('błąd programu'), NoMethodError.new('błąd metody')].each do |failure|
  T.script(lambda do |form|
    caught = assert_raises(failure.class) { T.button(form, 'Refresh').trigger(:press) }
    assert(caught.equal?(failure), 'Zastąpiono wyjątek callbacku')
    form.cancel_button.trigger(:press)
  end) { GameRoomTournaments::PublicPreview.new(**T.arguments(initial, load: -> { raise failure })).wait }
end
puts 'PASS jawny błąd kontraktu statusów; nie maskujemy wyjątków programu'

[nil, '', '   ', 42].each do |invalid|
  assert_raises(ArgumentError) { GameRoomTournaments::PublicPreview.new(**T.arguments(initial, mode_label: invalid)) }
  assert_raises(ArgumentError) { GameRoomTournaments::PublicPreview.new(**T.arguments(initial, actor: invalid)) }
end
puts 'PASS mode_label i actor muszą być jawnymi niepustymi String'

binary_actor = 'ŻANETA'.b.freeze
T.script(lambda do |form|
  assert(T.field(form, 'Status').text.include?('Already registered.'), 'Binarna tożsamość kompozycji zgubiła case-insensitive UTF8')
  form.cancel_button.trigger(:press)
end) { GameRoomTournaments::PublicPreview.new(**T.arguments(member_snapshot, actor: binary_actor)).wait }
assert(binary_actor.encoding == Encoding::ASCII_8BIT && binary_actor.frozen?, 'Zmieniono oryginalną tożsamość')
puts 'PASS aktor z binarnego źródła: członkostwo i niezmienione wejście'

# Granica konstruktora: obie strony pochodzą z rzeczywistych projekcji,
# ale publikacja może być zapamiętana przed zmianą aliasu lub konfliktem.
row = T.publication
cached = T.snapshot([row]).fetch('announcements').first
aliased = T.snapshot([row, row.merge('__id' => 7)], [T.registration(91)])
assert(cached.fetch('__id') == 11 && aliased.fetch('announcements').first.fetch('alias_ids') == [7, 11], 'Brak rzeczywistej zmiany kanonicznego aliasu')
assert(aliased.fetch('members').first.values_at('tournament_id', 'account') == [7, T::ACTOR.downcase], 'Brak zaakceptowanego członkostwa pod aliasem')
cases = {
  'alias_z_uczestnikiem' => aliased,
  'alias_bez_uczestnika' => T.snapshot([row, row.merge('__id' => 7)]),
  'brak' => T.snapshot([]),
  'konflikt_id' => T.snapshot([row, row.merge('rules' => 'Sprzeczny regulamin')]),
  'konflikt_klucza' => T.snapshot([row, row.merge('__id' => 7, 'rules' => 'Sprzeczny regulamin')]),
  'to_samo_id_inny_klucz' => T.snapshot([row.merge('publication_key' => 'different-intent')]),
  'to_samo_id_inny_autor' => T.snapshot([row.merge('__insertion_user' => 'Inny organizator')]),
  'to_samo_id_inna_tresc' => T.snapshot([row.merge('rules' => 'Inny regulamin')]),
  'sam_tytul_inny_rekord' => T.snapshot([T.publication(22).merge('title' => row.fetch('title'))])
}
failures = []
cases.each do |name, current|
  before = Marshal.dump([cached, current])
  calls, alerts, states = [], [], []
  reads = 0
  preview = nil
  T.script(lambda do |form|
    description = T.field(form, 'Tournament details').text.dup
    join = T.button(form, 'Join tournament')
    form.index = 2
    # Pierwszy render/Join, ten sam snapshot po Refresh, potem nieudany odczyt.
    3.times do |step|
      T.button(form, 'Refresh').trigger(:press) unless step.zero?
      states << T.field(form, 'Status').text
      join.trigger(:press)
      failures << "#{name}/#{step}: brak stanu nieaktualnego podglądu" unless states.last.include?('Outdated preview')
      failures << "#{name}/#{step}: niezgodna para uruchomiła join #{calls.inspect}" unless calls.empty?
      assert(form.index == 2, 'Odmowa lub Refresh zgubiły fokus Join')
      assert(preview.snapshot.equal?(current), 'Nie zachowano ostatniego snapshotu dla rodzica')
      failures << "#{name}/#{step}: podmieniono szczegóły nieaktualnego podglądu" unless T.field(form, 'Tournament details').text == description
    end
    form.cancel_button.trigger(:press)
  end) do
    preview = GameRoomTournaments::PublicPreview.new(**T.arguments(current, publication: cached,
      load: -> { reads += 1; reads == 1 ? current : nil }, join: ->(id) { calls << id; nil },
      alert: ->(message) { alerts << message }))
    preview.wait
  end
  failures << "#{name}: dodatkowy automatyczny odczyt #{reads}" unless reads == 2
  failures << "#{name}: odmowa bez komunikatu" unless alerts == states
  assert(Marshal.dump([cached, current]) == before && cached.frozen? && current.frozen?, 'Zmieniono wejściowe projekcje')
  puts "CHECK initial_pair #{name}: join_calls=#{calls.inspect}; reads=#{reads}; stale=#{states.map { |state| state.include?('Outdated preview') }.inspect}"
end
assert(failures.empty?, failures.join("\n"))
puts 'PASS niezgodna para od pierwszego renderu: alias, uczestnik, brak, konflikty, ID/klucz/autor/treść; Refresh nie odblokowuje obcego zamiaru'

# Zgodna para nadal działa, także z równą kopią zamiast tego samego obiektu.
[[], [T.registration(92)]].each do |registrations|
  current = T.snapshot([row, row.merge('__id' => 7)], registrations)
  equal_row = T.snapshot([row, row.merge('__id' => 7)]).fetch('announcements').first
  assert(equal_row.eql?(current.fetch('announcements').first) && !equal_row.equal?(current.fetch('announcements').first), 'Test wymaga równej, osobnej projekcji publikacji')
  calls = []
  T.script(lambda do |form|
    state = T.field(form, 'Status').text
    assert(!state.include?('Outdated preview'), 'Zgodny podgląd aliasów odrzucono')
    assert(state.include?('Already registered.') == !registrations.empty?, 'Zgodna para zgubiła członkostwo')
    assert(T.field(form, 'Tournament details').text.include?("Accepted participants: #{registrations.length}"), 'Zgodna para pokazuje błędną liczbę członków')
    2.times { T.button(form, 'Join tournament').trigger(:press) }
    assert(calls == (registrations.empty? ? [7] : []), 'Zgodna para nie zachowała dokładnego ID/pojedynczej próby')
    form.cancel_button.trigger(:press)
  end) do
    GameRoomTournaments::PublicPreview.new(**T.arguments(current, publication: equal_row,
      join: ->(id) { calls << id; nil }, load: -> { nil }, alert: ->(*) {})).wait
  end
end
puts 'PASS zgodna para aliasów i osobna równa kopia: canonical ID 7, rzeczywisty uczestnik, bez retry'
