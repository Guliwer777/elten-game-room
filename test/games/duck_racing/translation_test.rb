# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative '../../support/localization'
require_relative '../../../games/duck_racing_support/challenge_presentation'
require_relative '../../../tools/translations'

include DuckGameAdapterTest

root = File.expand_path('../../..', __dir__)
paths = ['games/duck_racing.rb'] +
  Dir.glob('{games/duck_racing_support,lib/duck_racing}/**/*.rb', base: root) +
  Dir.glob('lib/game_surfaces/*duck*.rb', base: root)
records, warnings = {}, []
paths.each do |path|
  GameRoomTranslationExtractor.extract_source(File.read(File.join(root, path), encoding: 'UTF-8'),
    path: path, warnings: warnings).each do |record|
    GameRoomTranslationExtractor.merge_record(records, **record)
  end
end
assert(warnings.empty?, "Unextractable Duck UI text: #{warnings.inspect}")
assert(records.length > 200, 'Incomplete Duck UI inventory')
assert(!File.exist?(File.join(root, 'locale/EN.po')), 'English must remain the source language')
assert(!File.exist?(File.join(root, 'locale/EN.mo')), 'English must remain the source language')

counts = [0, 1, 2, 5, 11, 22]
missing_messages = []
%w[PL CS ES RU].each do |code|
  po = GameRoomTranslationCatalog.read_po(File.join(root, "locale/#{code}.po"))
  GameRoomTranslationCatalog.validate!(po)
  mo = GameRoomLocalization::Catalog.new(File.binread(File.join(root, "locale/#{code}.mo")))
  records.each_value do |record|
    source, context = record.values_at(:msgid, :msgctxt)
    entry = po[context, source]
    unless entry && !entry.fuzzy? && !entry.msgstr.to_s.empty?
      missing_messages << "#{code}: #{source}"
      next
    end
    assert_equal(record[:msgid_plural], entry.msgid_plural, "#{code}: plural identity #{source}")
    (record[:msgid_plural] ? counts : [nil]).each do |count|
      text = mo.translate(source, context: context, count: count)
      assert(!text.to_s.empty?, "#{code}: absent binary translation #{source}, count #{count}")
      assert(text.valid_encoding?, "#{code}: invalid binary UTF-8 #{source}")
    end
  end
end
assert(missing_messages.empty?, "Missing Duck translations:\n#{missing_messages.join("\n")}")

names = {'en' => 'Duck Racing', 'pl' => 'Wyścigi kaczek', 'cs' => 'Závody kachen',
  'es' => 'Carrera de patos', 'ru' => 'Утиные гонки'}
# These expectations are independent of the catalog's plural expression.
# In particular Czech 22 has a different form from Polish and Russian 22.
forms = {
  'en' => {indices: [1, 0, 1, 1, 1, 1],
    cards: ['Draw %d card.', 'Draw %d cards.'],
    feathers: ['Receive %d feather.', 'Receive %d feathers.'],
    squares: ['Move forward %d square.', 'Move forward %d squares.'],
    sounds: ['%d sound', '%d sounds'], pairs: ['%d pair', '%d pairs']},
  'pl' => {indices: [2, 0, 1, 2, 2, 1],
    cards: ['Dobierz %d kartę.', 'Dobierz %d karty.', 'Dobierz %d kart.'],
    feathers: ['Otrzymujesz %d pióro.', 'Otrzymujesz %d pióra.', 'Otrzymujesz %d piór.'],
    squares: ['Przesuń się do przodu o %d pole.', 'Przesuń się do przodu o %d pola.', 'Przesuń się do przodu o %d pól.'],
    sounds: ['%d dźwięk', '%d dźwięki', '%d dźwięków'], pairs: ['%d para', '%d pary', '%d par']},
  'cs' => {indices: [2, 0, 1, 2, 2, 2],
    cards: ['Vezměte si %d kartu.', 'Vezměte si %d karty.', 'Vezměte si %d karet.'],
    feathers: ['Získáte %d pírko.', 'Získáte %d pírka.', 'Získáte %d pírek.'],
    squares: ['Posuňte se vpřed o %d políčko.', 'Posuňte se vpřed o %d políčka.', 'Posuňte se vpřed o %d políček.'],
    sounds: ['%d zvuk', '%d zvuky', '%d zvuků'], pairs: ['%d pár', '%d páry', '%d párů']},
  'es' => {indices: [1, 0, 1, 1, 1, 1],
    cards: ['Toma %d carta.', 'Toma %d cartas.'],
    feathers: ['Recibe %d pluma.', 'Recibe %d plumas.'],
    squares: ['Avanza %d casilla.', 'Avanza %d casillas.'],
    sounds: ['%d sonido', '%d sonidos'], pairs: ['%d pareja', '%d parejas']},
  'ru' => {indices: [2, 0, 1, 2, 2, 1],
    cards: ['Возьмите %d карту.', 'Возьмите %d карты.', 'Возьмите %d карт.'],
    feathers: ['Получите %d перо.', 'Получите %d пера.', 'Получите %d перьев.'],
    squares: ['Продвиньтесь вперёд на %d клетку.', 'Продвиньтесь вперёд на %d клетки.', 'Продвиньтесь вперёд на %d клеток.'],
    sounds: ['%d звук', '%d звука', '%d звуков'], pairs: ['%d пара', '%d пары', '%d пар']}
}
game = Harness.new.game
names.each do |code, expected_name|
  GameRoomTestLocalization.use_language(code)
  assert_equal(expected_name, game.name)
  if code == 'pl'
    descriptions = JSON.parse(File.read(File.join(root, 'test/fixtures/game_descriptions_pl.json'), encoding: 'UTF-8'))
    assert_equal(descriptions.fetch('duck_racing'), game.short_description)
  end
  counts.each_with_index do |count, index|
    expectation = forms.fetch(code)
    form = expectation.fetch(:indices).fetch(index)
    assert_equal(expectation[:cards][form] % count, game.effect_text([:cards, count]), "#{code}: cards #{count}")
    # Zero is a valid catalog count even though a zero-gain board effect is not generated.
    feathers = GameRoomLocalization.translate('Receive %{count} feather.',
      plural: 'Receive %{count} feathers.', count: count) % {count: count}
    squares = GameRoomLocalization.translate('Move forward %{count} square.',
      plural: 'Move forward %{count} squares.', count: count) % {count: count}
    assert_equal(expectation[:feathers][form] % count, feathers, "#{code}: feathers #{count}")
    assert_equal(expectation[:squares][form] % count, squares, "#{code}: squares #{count}")
    assert_equal("Alice: #{expectation[:sounds][form] % count}.",
      game.send(:challenge_details_text, 'simon', {0 => {score: count}}, nil, ['Alice']), "#{code}: sounds #{count}")
    assert_equal("Alice: #{expectation[:pairs][form] % count}.",
      game.send(:challenge_details_text, 'sound_memory', {0 => {score: count}}, nil, ['Alice']), "#{code}: pairs #{count}")
  end

  h = Harness.new
  h.start
  labels = LOGIC::Cards::TYPES.map { |card| game.card_name(card.id) }
  assert(labels.none? { |label| label.match?(/[()]/) }, "#{code}: a card name contains a second-language label")
  rendered = LOGIC::Cards::TYPES.map { |card| game.card_description(card.id) }
  rendered.concat((1..30).map { |square| game.square_text(h.replay, square) })
  book = JSON.parse(File.read(File.join(root, "tools/data/rulebooks/#{code.upcase}/duck_racing.json"), encoding: 'UTF-8'))
  if code != 'en'
    english_names = GameRoomTranslationExtractor.extract_source(
      File.read(File.join(root, 'games/duck_racing_support/presentation.rb'), encoding: 'UTF-8')
        .slice(/    def card_name\(type\).*?^    end/m), path: 'Duck card names').map { |entry| entry[:msgid] }
    texts = book.fetch('sections').flat_map { |section| [section['title'].fetch(code), *section['paragraphs'].map { |pair| pair.fetch(code) }] }
    assert(english_names.none? { |name| texts.any? { |text| text.include?(" (#{name})") } },
      "#{code}: a rulebook repeats an English card name")
  end
  titles = book.fetch('sections').to_h { |section| [section.fetch('id'), section.fetch('title').fetch(code)] }
  LOGIC::Challenges::TYPES.each do |type|
    rendered << game.challenge_name(type.id)
    unless code == 'en' || %w[quiz audio_ball axel_pong].include?(type.id)
      assert_equal(titles.fetch(type.id), game.challenge_name(type.id), "#{code}: challenge/rule title #{type.id}")
    end
    next if %w[audio_ball axel_pong].include?(type.id)
    engine = challenge_state(type.id)
    view = LOGIC::ChallengeEngine.view(engine, seat: 0)
    projection = LOGIC::ChallengePresentation.project(kind: type.id, view: view, viewer: 0)
    rendered.concat([projection[:header], *projection[:options]])
  end
  rendered.each do |text|
    assert(!text.empty? && text.valid_encoding?, "#{code}: empty or invalid rendered text")
    assert(!text.include?('%{'), "#{code}: unexpanded placeholder: #{text}")
  end
end
GameRoomTestLocalization.use_language('pl')
{'long_absence' => 2, 'golden_sleep' => 2, 'soporific_pill' => 3}.each do |card_type, turns|
  h = Harness.new
  h.start(seed: h.seed_for(card_type))
  card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == card_type }
  h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id, 'target' => 1}}, actor: 'Alice')
  current = h.replay
  assert_equal(turns, current.state[:race][:racers][1][:skip_turns])
  %w[Alice Bob].each do |viewer|
    speech = h.game.describe_event(h.events.last, h.repository, current, viewer)
    assert_equal(1, speech.count("Bob stoi #{turns} tury."), 'Card must announce the target and duration once')
    assert(speech.none? { |text| text.include?('pominie') })
  end
end
{1 => 'turę', 2 => 'tury', 5 => 'tur', 12 => 'tur', 22 => 'tury'}.each do |turns, noun|
  history = []
  game.send(:append_notices, history, [[:skip_added, 1, turns]], 201, %w[Alice Bob])
  assert_equal("Bob stoi #{turns} #{noun}.", history.first.text)
end
GameRoomTestLocalization.use_language('en')
puts "PASS Duck UI in five languages: #{records.length} messages, 37 cards, 30 squares, 20 challenge names and plural counts #{counts.join('/')}"
