require_relative "../../support/game_option_editor_native"

class QuestionOptionNativeGame < GameRoomGames::Base
  def id; "question_option_native_test"; end
  def option_definitions
    [GameRoomGames::OptionDefinition.new(key: "sets", label: "Question sets", kind: :multiple_values,
      default: ["general"], choices: %w[general special other].map { |id| GameRoomGames::OptionChoice.new(value: id, label: id) })]
  end
end

NativeOptionTest.language = "en"
game = QuestionOptionNativeGame.new
driver = NativeOptionTest::Driver.new(game)
control = driver.focus("sets")
NativeOptionTest.assert(control.multiselections == [0], "native defaults lost the selected set")
driver.press([40])
driver.press([32])
NativeOptionTest.assert(control.multiselections == [0, 1], "native Space did not select a second set")
driver.focus(driver.form.accept_button)
driver.press([13])
result = driver.finished
NativeOptionTest.assert(result["sets"] == %w[general special], "native submit lost stable IDs")
NativeOptionTest.assert(driver.program.writes.last[1].fetch(game.id).fetch("sets") == %w[general special], "native persistence changed IDs")

driver = NativeOptionTest::Driver.new(game, initial_options: { "sets" => ["special"] })
control = driver.focus("sets")
driver.press([40])
driver.press([32])
NativeOptionTest.assert(control.multiselections.empty?, "native Space did not clear the saved set")
driver.focus(driver.form.accept_button)
driver.press([13])
NativeOptionTest.assert(driver.finished["sets"] == [], "native empty selection got a fallback")

driver = NativeOptionTest::Driver.new(game)
driver.focus("sets")
driver.press([32])
driver.press([27])
NativeOptionTest.assert(driver.finished == nil && driver.program.writes.empty?, "native Escape stored cancelled choices")

driver = NativeOptionTest::Driver.new(game, initial_options: { "sets" => ["removed"] })
control = driver.control("sets")
NativeOptionTest.assert(control.options.last == "Unavailable choice: removed" && control.multiselections == [3], "native control hid an unavailable selection")
driver.focus(driver.form.accept_button)
driver.press([13])
NativeOptionTest.assert(driver.program.alerts.last.to_s.include?("unavailable choice"), "native invalid selection passed validation")
driver.focus(control)
3.times { driver.press([40]) }
driver.press([32])
driver.press([36])
driver.press([32])
driver.focus(driver.form.accept_button)
driver.press([13])
NativeOptionTest.assert(driver.finished["sets"] == ["general"], "native control could not explicitly replace missing resource")

language_game = Class.new(GameRoomGames::Base) do
  def id; "question_option_native_language_test"; end
  def option_definitions
    [GameRoomGames::OptionDefinition.new(key: "language", label: "Language", kind: :choice, default: "en",
      choices: %w[en pl-PL].map { |id| GameRoomGames::OptionChoice.new(value: id, label: id) })]
  end
  def effective_option_definitions(selected = {})
    ids = selected.fetch("language", "en") == "en" ? %w[general special] : %w[ogolny wiedzmin]
    super + [GameRoomGames::OptionDefinition.new(key: "sets", label: "Question sets", kind: :multiple_values,
      default: ["general"], choices: ids.map { |id| GameRoomGames::OptionChoice.new(value: id, label: id) })]
  end
  def option_editor_changes(previous, current)
    previous["language"] == current["language"] ? {} : { "sets" => [current["language"] == "en" ? "general" : "ogolny"] }
  end
end.new
driver = NativeOptionTest::Driver.new(language_game)
sets = driver.control("sets")
language = driver.focus("language")
driver.press([40])
NativeOptionTest.assert(driver.form.fields[driver.form.index].equal?(language), "native checklist catalogue refresh stole focus")
NativeOptionTest.assert(sets.options == %w[ogolny wiedzmin] && sets.multiselections == [0], "native catalogue refresh lost explicit language default")
driver.focus(sets)
driver.press([40])
driver.press([32])
driver.focus(driver.form.accept_button)
driver.press([13])
NativeOptionTest.assert(driver.finished["sets"] == %w[ogolny wiedzmin], "native refreshed choices did not preserve language-specific IDs")
puts "PASS native stable checklist: #{NativeOptionTest.checks} checks using ELTEN ListBox Space/Tab/Enter/Escape handlers"
