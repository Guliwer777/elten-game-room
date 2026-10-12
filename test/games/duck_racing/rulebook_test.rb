require "json"
require_relative "../../support/rules_native_navigation"
require_relative "../../../games/duck_racing"
require_relative "../../../games/generated/rulebooks/duck_racing"
require_relative "../../../tools/compile-rulebooks"

root = File.expand_path("../../..", __dir__)
output = "games/generated/rulebooks/duck_racing.rb"
generated = GameRoomRulebookCompiler.outputs(root).fetch(output)
assert(File.binread(File.join(root, output)) == generated.b, "Duck Racing generated rules are stale")
fallback_source = JSON.parse(File.read(File.join(root, "tools/data/rulebooks/duck_racing.json"), encoding: "UTF-8"))
english_source = JSON.parse(File.read(File.join(root, "tools/data/rulebooks/EN/duck_racing.json"), encoding: "UTF-8"))
english_sections = lambda do |book|
  book.fetch("sections").map do |section|
    [section.fetch("id"), section.fetch("title").fetch("en"),
      section.fetch("paragraphs").map { |pair| pair.fetch("en") }]
  end
end
# Complete editions own their wording. The root book provides the English
# fallback; its auxiliary Polish fields come from PO, not the complete PL book.
assert(fallback_source.fetch("source") == english_source.fetch("source"), "English fallback source differs")
assert(english_sections.call(fallback_source) == english_sections.call(english_source), "English fallback differs from the complete edition")
assert(fallback_source.fetch("option_chapters") == english_source.fetch("option_chapters"), "English fallback option chapters differ")
GameRoomTestLocalization.use_language("en")
compiled_fallback = GameRoomGames::DuckRacing.new.send(:generated_rule_sections)
assert(compiled_fallback.map { |section| [section.id.to_s, section.title, section.paragraphs] } == english_sections.call(english_source),
  "generated English fallback differs from its source")
challenge_ids = GameRoomDuckRacing::Challenges::BY_ID.keys
checks = []

ENV.fetch("DUCK_RULE_LANGUAGES", "en,pl,cs,es,ru").split(",").each do |language|
  path = File.join(root, "tools/data/rulebooks", language.upcase, "duck_racing.json")
  assert(File.file?(path), "#{language}: Duck Racing rules are missing")
  source = JSON.parse(File.read(path, encoding: "UTF-8"))
  GameRoomTestLocalization.use_language(language)
  game = GameRoomGames::DuckRacing.new
  expected = source.fetch("sections")
  ids = expected.map { |section| section.fetch("id") }
  assert(ids.uniq == ids && ids.last == "controls", "#{language}: invalid chapter order")
  assert((challenge_ids - ids).empty?, "#{language}: a challenge has no rule chapter")
  actual = game.send(:localized_rule_sections)
  assert(actual.map { |section| section.id.to_s } == ids, "#{language}: generated chapter order differs")
  actual.zip(expected).each do |section, authored|
    assert(section.title == authored.fetch("title").fetch(language), "#{language}: generated title differs")
    assert(section.paragraphs == authored.fetch("paragraphs").map { |pair| pair.fetch(language) }, "#{language}/#{section.id}: generated text differs")
    assert(([section.title] + section.paragraphs).all? { |text| text.valid_encoding? && !text.strip.empty? && !text.include?("TODO") }, "#{language}/#{section.id}: unfinished text")
  end
  keys = game.effective_option_definitions.map(&:key) - ["bot_delay"]
  coverage = source.fetch("option_chapters")
  assert(coverage.keys.sort == keys.sort, "#{language}: an option lacks a chapter")
  assert(coverage.values.all? { |chapter| ids.include?(chapter) && chapter != "controls" }, "#{language}: invalid option chapter")
  book = game.rule_book(options: game.default_options)
  assert(book.documents.map(&:id) == [:rules, :controls, :current_options], "#{language}: document structure changed")
  screen = GameRoomScreens::GameRules.new(book, game_shortcuts: ["Context shortcut"])
  bullet_count = 0
  screen.instance_variable_get(:@documents).each do |document|
    field = screen.send(:section_form, document).fields.first
    if document.id == :controls
      assert(field.options == ["Context shortcut"], "#{language}: fallback controls replaced current controls")
      next
    end
    check_document(field, document, "duck_racing/#{language}/#{document.id}")
    list_items = elements(field, EditBox::Element::ListItem)
    expected_items = document.sections.flat_map(&:paragraphs).select { |line| line.match?(/\A(?:- |\d+\. )/) }
    assert(list_items.map { |item| field.text_range(item.from, item.to) } == expected_items, "#{language}: native lists differ")
    bullet_count += list_items.length
  end
  checks << {language: language, chapters: ids.length, challenges: challenge_ids.length, lists: bullet_count, native_documents: 3}
end

GameRoomTestLocalization.use_language("missing_translation")
fallback_document = GameRoomGames::DuckRacing.new.rule_book.documents.first
expected_fallback = english_sections.call(english_source).reject { |id, _title, _paragraphs| id == "controls" }
assert(fallback_document.sections.map { |section| [section.id.to_s, section.title, section.paragraphs] } == expected_fallback,
  "missing interface catalog did not retain the complete English rulebook")

puts JSON.pretty_generate(status: "PASS", checks: checks, fallback: "English source, generated fallback and missing catalog agree",
  scope: "Duck Racing sources, generated rules and native rules controls; no live client or package test")
