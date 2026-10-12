require_relative "../../support/binary_rule_dictionary"
require_relative "../../support/authored_rulebooks"

def assert(value, message)
  raise message unless value
end

game = GameRoomGames::Krowa.new
%w[pl en fallback].each do |language|
  $rules_english = language != "pl"
  GameRoomTestLocalization.use_language(language)
  expected = language == "pl" ? ["Liczba liter", "Kryterium wyniku"] : ["Number of letters", "Scoring criterion"]
  labels = game.option_definitions.to_h { |definition| [definition.key, definition.label] }
  assert(labels.values_at("length", "race_scoring") == expected, "Redundant Krowa labels in #{language}: #{labels}")
  {"daily" => %w[variant], "random" => %w[variant length], "race" => %w[variant length race_scoring], "tower" => %w[variant]}.each do |variant, keys|
    options = game.normalize_options("variant" => variant)
    actual = game.effective_option_definitions(options).select { |definition| game.option_visible?(definition, options) }.map(&:key)
    assert(actual == keys, "Visibility changed for #{variant}")
  end
  rules = game.rule_book.documents.first.text
  # The supplied rules explain options in natural prose rather than repeating
  # their exact UI labels. Check the complete replacement through binary loading.
  text_language = language == "pl" ? "pl" : "en"
  GameRoomTest::Rulebooks.sections('krowa', language).reject { |section| section.fetch("id") == "controls" }.each do |section|
    ([section.fetch("title")] + section.fetch("paragraphs")).each do |pair|
      text = pair.fetch(text_language)
      assert(rules.include?(text), "Krowa rules omit or mistranslate #{section.fetch('id')} in #{language}: #{text}")
    end
  end
end
puts "PASS Krowa: concise labels, complete supplied rules and variant visibility in PL/EN/fallback"
