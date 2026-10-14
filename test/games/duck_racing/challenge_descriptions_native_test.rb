require_relative "../../support/game_option_editor_native"

def assert(condition, message)
  NativeOptionTest.assert(condition, message)
end

NativeOptionTest.native_method(ListBox, :speak_item_option, "src/ui/controls/list_box.rb")
NativeOptionTest.native_method(ListBox, :lspeak, "src/ui/controls/list_box.rb")
NativeOptionTest.native_method(ListBox, :update, "src/ui/controls/list_box.rb")
expected_ids = %w[rock_paper_scissors dice_duel blackjack risky_dice guess_number
  copy_number arithmetic race_question numbered_balls count_ducks rhythm sound_order
  simon sound_memory hit_duck quiz audio_ball axel_pong]
english = nil
examples = {
  "en" => "Each player rolls once. The highest roll wins.",
  "pl" => "Każdy rzuca kością raz. Wygrywa najwyższy wynik.",
  "cs" => "Každý hráč jednou hodí kostkou. Vyhrává nejvyšší hod.",
  "es" => "Cada jugador tira el dado una vez. Gana quien saque el número más alto.",
  "ru" => "Каждый игрок один раз бросает кубик. Побеждает тот, у кого выпало больше."
}
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = GameRoomGames::DuckRacing.new
  choices = game.option_definitions.find { |entry| entry.key == "challenges" }.choices
  assert(choices.map(&:value) == expected_ids, "#{language}: challenge IDs or order changed")
  assert(choices[1].description == examples.fetch(language), "#{language}: wrong description language")
  english ||= choices.map(&:description)
  table_summary = game.table_options_announcement(game.default_options)
  choices.each_with_index do |choice, index|
    text = choice.description
    assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?, "#{language}: invalid description encoding")
    assert(!text.empty? && text.length < 240, "#{language}: missing or overlong description for #{choice.value}")
    assert(language == "en" || text != english[index], "#{language}: English fallback for #{choice.value}")
    assert(!table_summary.include?(text), "#{language}: description leaked into the table summary")
  end

  driver = NativeOptionTest::Driver.new(game, creating_table: true)
  control = driver.focus("challenges")
  assert(control.instance_of?(ListBox), "Challenge choices stopped using the native ListBox")
  assert(control.options == choices.map(&:label), "Descriptions changed native labels")
  assert(control.multiselections == (0...18).to_a, "Descriptions changed defaults")
  choices.each_with_index do |choice, index|
    driver.press([40]) if index > 0
    spoken = NativeOptionUI.spoken.last
    assert(control.index == index, "Native Down did not browse #{choice.value}")
    assert(spoken.end_with?("\n" + choice.description), "#{language}: description is not the last part of the utterance")
    prefix = spoken.delete_suffix("\n" + choice.description)
    assert(prefix.include?(choice.label) && prefix.end_with?("(#{p_("EAPI_Common", "Ticked")})"),
      "#{language}: description replaced or preceded the native checked state")
    assert(spoken.scan(choice.description).length == 1, "#{language}: duplicate description")
  end
  # Toggling keeps the native short state announcement; revisiting the row
  # appends its description after the new unchecked state.
  driver.press([32])
  assert(!control.multiselections.include?(17), "Space did not clear the last challenge")
  assert(NativeOptionUI.spoken.last == p_("EAPI_Form", "Unchecked"), "Space repeated the whole description")
  driver.press([38])
  driver.press([40])
  assert(NativeOptionUI.spoken.last.end_with?("(#{p_("EAPI_Common", "Unticked")})\n" + choices.last.description),
    "Revisiting an unchecked challenge read the wrong state or description")
  before = NativeOptionUI.spoken.length
  control.focus(nil, nil, control.header, false)
  assert(NativeOptionUI.spoken.length == before, "Silent focus spoke the description")
  driver.focus(driver.form.accept_button)
  driver.press([13])
  saved = driver.finished.fetch(:game_options)
  assert(saved.fetch("challenges") == expected_ids[0...-1].sort, "Native submit changed the sorted stable IDs")
  assert(driver.program.remembers.last.last.fetch("challenges") == expected_ids[0...-1].sort, "Remembered choices changed")

  driver = NativeOptionTest::Driver.new(game, initial_options: saved)
  control = driver.focus("challenges")
  assert(control.multiselections == (0...17).to_a, "Editing lost the previous selection")
  driver.press([32])
  driver.press([27])
  assert(driver.finished.nil?, "Escape saved a changed challenge selection")
  driver.pristine
end

# A missing app translation with a translated host must still work when
# source text includes non-ASCII bytes. Do not change the original strings.
raw = "A melody — five notes.".b.freeze
choice = GameRoomGames::OptionChoice.new(value: "stable", label: "Melody", description: raw)
assert(raw.encoding == Encoding::ASCII_8BIT && choice.description.encoding == Encoding::UTF_8,
  "Description normalization changed the input or left binary text")
NativeOptionTest.language = "en"
NativeOptionUI.language = "pl"
fixture = Class.new(GameRoomGames::Base) do
  attr_accessor :test_description
  def id; "described_options_native"; end
  def option_definitions
    [
      GameRoomGames::OptionDefinition.new(key: "details", label: "Descriptions", kind: :boolean, default: false),
      GameRoomGames::OptionDefinition.new(key: "plain", label: "Plain choice", kind: :choice, default: "a",
        choices: [GameRoomGames::OptionChoice.new(value: "a", label: "Plain A")])
    ]
  end
  def effective_option_definitions(selected = {})
    super + [GameRoomGames::OptionDefinition.new(key: "choices", label: "Choices", kind: :multiple_values,
      default: ["stable"], choices: [GameRoomGames::OptionChoice.new(value: "stable", label: "Melody",
        description: selected["details"] ? test_description : nil)])]
  end
end.new
fixture.test_description = raw
driver = NativeOptionTest::Driver.new(fixture)
control = driver.focus("choices")
assert(!control.is_a?(GameRoomOptionEditor::ChoiceDescriptions), "An ordinary checklist opted in")
plain = driver.control("plain")
assert(!plain.is_a?(GameRoomOptionEditor::ChoiceDescriptions), "An ordinary choice list opted in")
driver.toggle("details")
driver.focus(control)
assert(NativeOptionUI.spoken.last.end_with?("\n" + choice.description), "Refreshed descriptions were not enabled")
assert(control.multiselections == [0] && control.index == 0, "Description refresh lost selection or focus")
driver.toggle("details")
driver.focus(control)
assert(!NativeOptionUI.spoken.last.include?(choice.description), "Removed description stayed attached to the row")
driver.focus(plain)
assert(!NativeOptionUI.spoken.last.include?(choice.description), "Description leaked into another field")
driver.press([27])
assert(driver.finished.nil?, "Cancelling the dynamic editor saved options")
driver.pristine

# Removed catalog entries remain clearable and do not inherit a neighboring
# row's description. No network requests or game resources are needed.
NativeOptionTest.language = "en"
driver = NativeOptionTest::Driver.new(GameRoomGames::DuckRacing.new,
  initial_options: { "challenges" => ["simon", "removed"] })
control = driver.focus("challenges")
driver.press([35])
assert(control.options[control.index] == "Unavailable choice: removed", "Removed challenge was hidden")
assert(NativeOptionUI.spoken.last.end_with?("(Ticked)"), "Removed challenge inherited a description")
driver.press([27])
assert(driver.finished.nil?, "Cancelling unknown choices saved them")

puts "PASS challenge descriptions: #{NativeOptionTest.checks} checks; five languages, binary sources, native focus/Down/Space/Tab/Enter/Escape, dynamic refresh and missing choices; no network or live games"
