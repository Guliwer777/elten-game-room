require_relative "../../support/assertions"
require_relative "../../../games/base"

include GameRoomTest::Assertions

class QuestionOptionValuesGame < GameRoomGames::Base
  attr_accessor :choice_ids

  def initialize; @choice_ids = %w[set.general set.special set.other]; end
  def id; "question_option_values_test"; end
  def name; "Option values test"; end
  def option_definitions
    choices = choice_ids.map { |id| GameRoomGames::OptionChoice.new(value: id, label: id.to_s.upcase) }
    [
      GameRoomGames::OptionDefinition.new(key: "sets", label: "Question sets", kind: :multiple_values,
        default: ["set.general"], choices: choices),
      GameRoomGames::OptionDefinition.new(key: "legacy", label: "Legacy mask", kind: :multiple_choice,
        default: 1, choices: choices)
    ]
  end
end

game = QuestionOptionValuesGame.new
assert_equal(["set.general"], game.default_options["sets"])
raw = { sets: ["set.special", "set.general", "set.special"], legacy: ["set.special", "set.other"] }
before = Marshal.dump(raw)
normalized = game.normalize_options(raw)
assert_equal(["set.general", "set.special"], normalized["sets"])
assert_equal(6, normalized["legacy"])
assert_equal(before, Marshal.dump(raw), "normalization mutated the caller")
assert_equal(nil, game.validation_error(normalized))
assert_equal(normalized, game.options_from_json(JSON.generate(normalized)))
assert_equal(%w[sets legacy], game.remembered_option_definitions(game.option_definitions).map(&:key))
assert_equal(%w[sets legacy], game.remembered_option_definitions(game.option_definitions, options: normalized).map(&:key))

game.choice_ids = %w[set.other set.special set.general]
reordered = game.options_from_json(JSON.generate(normalized))
assert_equal(normalized["sets"], reordered["sets"], "catalogue order changed stable IDs")
assert_equal(6, reordered["legacy"], "legacy masks unexpectedly changed semantics")
assert_equal(nil, game.validation_error(reordered))
assert(game.rules_options_text(reordered).include?("Question sets: SET.SPECIAL, SET.GENERAL"))
assert_equal([], game.normalize_options("sets" => [])["sets"])
assert_equal(nil, game.validation_error(game.normalize_options("sets" => [])), "generic checklist must allow zero; game validates requirements")
assert_equal(["set.general"], game.normalize_options({})["sets"], "missing key lost its declared default")
assert_equal(nil, game.validation_error({}), "missing key was treated as corrupt data")

[["missing"], [1], "set.general", 3, nil, ["\xFF".dup.force_encoding(Encoding::UTF_8)]].each do |invalid|
  values = game.normalize_options("sets" => invalid)
  assert_equal(invalid, values["sets"], "invalid selection was silently replaced")
  assert(game.validation_error(values).to_s.include?("unavailable choice"), "invalid selection was accepted: #{invalid.inspect}")
end
game.choice_ids = %w[set.general set.general]
assert_raises(ArgumentError) { game.validation_error(game.default_options) }
game.choice_ids = ["set.general", 4]
assert_raises(ArgumentError) { game.validation_error(game.default_options) }
game.choice_ids = ["set.general", ""]
assert_raises(ArgumentError) { game.validation_error(game.default_options) }

# Existing numeric masks keep their old truncation and Array conversion.
game.choice_ids = %w[set.general set.special set.other]
assert_equal(7, game.normalize_options("legacy" => 15)["legacy"])
assert_equal(0, game.normalize_options("legacy" => ["missing"])["legacy"])
assert_equal(5, game.normalize_options("legacy" => %w[set.general set.other])["legacy"])
assert_equal(1, game.default_options["legacy"])
puts "PASS stable checklist normalization: JSON round trip, reordered choices, empty/default/unknown/duplicate IDs, summaries and unchanged legacy masks"
