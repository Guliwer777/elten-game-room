require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/question_sets"

include GameRoomTest::Assertions
adapter = GameRoomDuckRacing::QuestionSets
registry = GameRoomContent::Registry.new
%w[en pl-PL].each do |language|
  registry.register_language(GameRoomContent::LanguageProfile.new(id: language, label: language,
    alphabet: ("a".."z").to_a, normalizer: ->(text) { text.downcase }))
end
question = ->(id, correct) { { "id" => id, "category" => "Example", "prompt" => "Which answer?", "correct" => correct, "wrong" => %w[one two three] } }
loaded = []
[
  ["first", "en", [question.call("a", "four"), question.call("b", "five")]],
  ["first", "pl-PL", [question.call("pl", "cztery")]],
  ["second", "en", [question.call("s", "six")]],
  ["unselected", "en", [question.call("u", "seven")]]
].each do |set_id, language, questions|
  id = "test.#{set_id}.#{language.downcase}"
  metadata = { id: id, set_id: "test.#{set_id}", kind: "quiz", language_id: language,
    version: 1, title: set_id, game_ids: ["quiz"], entry_count: questions.length }
  inline = GameRoomContent::Pack.new(**metadata, data: { "questions" => questions })
  registry.register_pack(GameRoomContent::Pack.new(**metadata, checksum: inline.checksum,
    loader: -> { loaded << id; { "questions" => questions } }))
end
catalog = adapter.catalog(registry: registry)
assert_equal([], loaded, "opening the checklist parsed lazy packs")
assert_equal(%w[test.first test.second test.unselected], catalog.map { |entry| entry[:set_id] })
assert_equal(%w[en pl-PL], catalog.first[:languages].map { |entry| entry[:language_id] })
assert_equal([2, 1], catalog.first[:languages].map { |entry| entry[:question_count] })
assert_equal(%w[test.first test.second test.unselected], adapter.choices(language: "en", registry: registry).map { |entry| entry[:value] })
assert_equal(["test.first"], adapter.choices(language: "pl-PL", registry: registry).map { |entry| entry[:value] })
assert_equal([], adapter.choices(language: "ru-RU", registry: registry))
assert_raises(adapter::Unavailable) { adapter.defaults("en", registry: registry) }
assert_equal([], loaded, "checklist/default discovery parsed lazy packs")

pool = adapter.prepare(selection: { "test.first" => "en", "test.second" => "en" },
  weights: { "test.first" => 1, "test.second" => 1 }, registry: registry)
assert_equal(%w[test.first.en test.second.en], loaded)
correct_indices = []
set_counts = Hash.new(0)
500.times do |seed|
  drawn = pool.draw(seed: seed)
  set_counts[drawn[:set_id]] += 1
  assert_equal(drawn, pool.draw(seed: seed))
  assert(%w[test.first test.second].include?(drawn[:set_id]))
  assert_equal("en", drawn[:language_id])
  correct_indices << drawn[:correct_index]
  expected = { "a" => "four", "b" => "five", "s" => "six" }.fetch(drawn[:question_id])
  assert_equal(expected, drawn[:choices].fetch(drawn[:correct_index]))
  assert_equal(4, drawn[:choices].uniq.length)
  view = adapter.public_view(drawn)
  assert_equal(false, view.key?(:correct_index))
  assert_equal(false, view.key?(:correct))
  view[:choices][0].replace("altered")
  assert_equal(expected, drawn[:choices].fetch(drawn[:correct_index]))
end
assert_equal([0, 1, 2, 3], correct_indices.uniq.sort)
assert(set_counts.values.all? { |count| count.between?(200, 300) }, "two-question set was weighted by size instead of equally to the one-question set")
assert_equal(64, pool.fingerprint.length)
assert_equal({ "test.first" => "en", "test.second" => "en" }, pool.selection)
same = adapter.prepare(selection: { "test.second" => "en", "test.first" => "en" },
  weights: { "test.second" => 1, "test.first" => 1 }, registry: registry)
assert_equal(pool.fingerprint, same.fingerprint)
assert_equal(pool.draw(seed: 21), same.draw(seed: 21), "Hash insertion order changed the draw")
equal_weight = adapter.prepare_selected(ids: %w[test.first test.second], language: "en", registry: registry)
assert_equal(pool.fingerprint, equal_weight.fingerprint)
assert_equal(pool.draw(seed: 21), equal_weight.draw(seed: 21))
assert_equal({ "test.first" => 1, "test.second" => 1 }, equal_weight.weights)
[[], ["test.first", "test.first"], ["missing"], [1], "test.first"].each do |ids|
  assert_raises(adapter::Unavailable) { adapter.prepare_selected(ids: ids, language: "en", registry: registry) }
end
polish = adapter.prepare(selection: { "test.first" => "pl-PL" }, weights: { "test.first" => 1 }, registry: registry)
assert_equal("pl", polish.draw(seed: 21)[:question_id])
assert_equal("pl-PL", polish.draw(seed: 21)[:language_id])
assert_equal(false, loaded.include?("test.unselected.en"))

[
  [{}, {}],
  [{ "test.first" => "ru-RU" }, { "test.first" => 1 }],
  [{ "missing" => "en" }, { "missing" => 1 }],
  [{ "test.first" => "en" }, {}],
  [{ "test.first" => "en" }, { "test.first" => 0 }],
  [{ "test.first" => "en" }, { "test.first" => -1 }],
  [{ "test.first" => "en" }, { "test.first" => 1.0 }],
  [{ "test.first" => "en" }, { "test.first" => 1, :wrong => 1 }],
  [{ first: "en" }, { first: 1 }]
].each do |selection, weights|
  assert_raises(adapter::Unavailable) { adapter.prepare(selection: selection, weights: weights, registry: registry) }
end
assert_raises(ArgumentError) { adapter.prepare(selection: { "test.first" => "en" }, registry: registry) }
assert_raises(ArgumentError) { pool.draw(seed: "random") }
[
  [],
  [question.call("a", "four"), question.call("a", "five")],
  [question.call("a", "One")],
  [question.call("a", "four").merge("wrong" => %w[one two])],
  [question.call("a", "four").merge("prompt" => " ")]
].each_with_index do |invalid_questions, index|
  id = "invalid.#{index}"
  registry.register_pack(GameRoomContent::Pack.new(id: id, set_id: id, kind: "quiz", language_id: "en",
    version: 1, title: id, game_ids: ["quiz"], data: { "questions" => invalid_questions }))
  assert_raises(adapter::Unavailable) { adapter.prepare(selection: { id => "en" }, weights: { id => 1 }, registry: registry) }
end

puts "PASS Duck Racing question selection: lazy catalogue, stable set/language IDs, explicit weights, deterministic ABCD and no fallback"
