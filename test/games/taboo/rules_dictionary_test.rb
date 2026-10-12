require_relative "../../support/binary_rule_dictionary"
require_relative "../../support/authored_rulebooks"

game = GameRoomGames::Taboo.new
authoring = JSON.parse(File.read(File.join(BinaryRulesLoad::ROOT, "tools/data/rulebooks/taboo.json"), encoding: "UTF-8"))
english_sources = authoring.fetch("sections").flat_map { |section| section.fetch("paragraphs").map { |pair| pair.fetch("en") } }
  .reject(&:ascii_only?)
raise "Missing non-ASCII fixtures" if english_sources.empty?
english_sources.each do |source|
  raise "Fixture does not reproduce native lookup failure" unless _(source) == source
  raise "Local rule translation did not recover binary key" unless GameRoomRules.translate(source) == RULES_CATALOG.fetch(source)
end

original_source = BinaryRulesLoad.read(File.join(BinaryRulesLoad::ROOT, "games/taboo_ui.rb"))
raise "Taboo sources lack declared encoding" unless original_source.start_with?("# encoding: UTF-8")
[false, true].each do |english|
  $rules_english = english
  GameRoomTestLocalization.use_language(english ? :en : :pl)
  documents_by_language = %w[pl-PL en].map do |language|
    options = game.normalize_options("content_language_id" => language)
    game.rule_book(options: options).documents.take(2)
  end
  raise "Rules followed card language instead of interface" unless documents_by_language[0].map(&:text) == documents_by_language[1].map(&:text)
  documents_by_language.flatten.each do |document|
    raise "Bad rule encoding" unless document.text.encoding == Encoding::UTF_8 && document.text.valid_encoding?
  end
  combined = documents_by_language.first.map(&:text).join("\n")
  GameRoomTest::Rulebooks.paragraphs('taboo', english ? :en : :pl).each do |expected|
    raise "Mixed-language Taboo document" unless combined.include?(expected)
  end
end
puts "PASS Taboo: binary/native dictionary, complete rules and shortcuts, PL/EN independent of card language"
