require_relative "../support/binary_rule_dictionary"

def assert(value, message); raise message unless value; end

dictionary, english = $rules_dictionary, $rules_english
previous_language = GameRoomTestLocalization.language
begin
  [:pl, :en, :fallback].each do |language|
    $rules_english = language == :en
    GameRoomTestLocalization.use_language(language)
    $rules_dictionary = language == :fallback ? BinaryRuleDictionary.new({}) : dictionary
    # UNO's face names are constants translated at load time, as in a new
    # app runtime. Reload only the class with the selected native dictionary.
    GameRoomGames.send(:remove_const, :Uno)
    path = File.join(BinaryRulesLoad::ROOT, 'games/uno.rb')
    BinaryRulesLoad.instance_variable_get(:@loaded).delete(path)
    BinaryRulesLoad.load(path)
    game = GameRoomGames::Uno.new
    state = game.send(:initial_state, %w[Alice Bob], game.default_options)
    colours = language == :pl ? %w[czerwony żółty zielony niebieski pomarańczowy różowy turkusowy fioletowy] :
      %w[red yellow green blue orange pink teal purple]
    GameRoomGames::Uno::COLOR_NAMES.keys.each_with_index do |colour, i|
      text = game.send(:uno_label, "#{colour}9a", state)
      assert(text == "#{colours[i]} 9", "#{language}: colour/number contains a comma or wrong name: #{text}")
      assert(text.valid_encoding?, "#{language}: invalid card encoding")
    end
    labels = {
      'YSa' => ['żółty pomiń', 'yellow skip'],
      'YVa' => ['żółty zmiana kierunku', 'yellow reverse'],
      'YDa' => ['żółty dobierz dwie', 'yellow draw two'],
      'YEa' => ['żółty pomiń wszystkich', 'yellow skip everyone'],
      'YAa' => ['żółty odrzuć wszystkie', 'yellow discard all'],
      'YXa' => ['żółty dobierz cztery', 'yellow draw four'],
      'NW0' => ['zmiana koloru', 'wild'],
      'NF0' => ['zmiana koloru i dobierz cztery', 'wild draw four'],
      'N60' => ['zmiana koloru i dobierz sześć', 'wild draw six'],
      'NT0' => ['zmiana koloru i dobierz dziesięć', 'wild draw ten'],
      'NR0' => ['zmiana koloru i kierunku oraz dobierz cztery', 'wild reverse draw four'],
      'NC0' => ['ruletka kolorów', 'wild colour roulette'],
      'YIa' => ['żółty dobierz jedną', 'yellow draw one'],
      'YHa' => ['żółty dobierz pięć', 'yellow draw five'],
      'YLa' => ['żółty odwróć karty', 'yellow flip'],
      'NB0' => ['brzęczyk', 'buzzer']
    }
    labels.each do |card, names|
      expected = names[language == :pl ? 0 : 1]
      actual = game.send(:uno_label, card, state)
      assert(actual == expected, "#{language}: #{card}: #{actual.inspect}, expected #{expected.inspect}")
    end
    state[:options]['deck'] = 'flip'
    state[:side] = :light
    assert(game.send(:uno_label, 'NF0', state) == (language == :pl ? 'zmiana koloru i dobierz dwie' : 'wild draw two'), 'Flip light name')
    state[:side] = :dark
    assert(game.send(:uno_label, 'NC0', state) == (language == :pl ? 'dobieranie do wskazanego koloru' : 'wild draw colour'), 'Flip dark name')

    # Real hand and table announcements share the label, not just this helper.
    state.update(phase: :playing, current_player: 'Alice', colour: 'Y', discard: ['Y9a'],
      hands: {'Alice' => ['YSa', 'NW0'], 'Bob' => ['R1a']})
    replay = GameRoomGames::Replay.new(players: state[:players], current_player: 'Alice', history: [], accepted_events: [], state: state)
    hand = GameSurfaces.build(game.surface_spec(replay, 'Alice'))
    assert(hand.fields.first.options == (language == :pl ? ['żółty pomiń', 'zmiana koloru'] : ['yellow skip', 'wild']), 'hand ignored localized names')
    table = game.custom_game_shortcuts(replay, 'Alice').find { |key| key.key == 'c' && key.modifiers.empty? }
    assert(table.message == (language == :pl ? 'żółty 9' : 'yellow 9'), 'table card ignored localized name')

    rummy = GameRoomGames::Rummy.new
    assert(rummy.id == 'rummy', 'localized name changed game/save ID')
    assert(rummy.name == (language == :pl ? 'Remik' : 'Rummy'), "#{language}: game list name")
    text = rummy.rule_book(options: rummy.default_options).documents.first.text
    assert(text.include?(language == :pl ? 'W Remiku' : 'In Rummy'), "#{language}: rule book name")
  end
ensure
  $rules_dictionary, $rules_english = dictionary, english
  GameRoomTestLocalization.use_language(previous_language)
end
puts 'PASS UNO classic/No Mercy/Flip names, hand and C; Remik name with stable ID; binary PL/EN/fallback dictionary'
