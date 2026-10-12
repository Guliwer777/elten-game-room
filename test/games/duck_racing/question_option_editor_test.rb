require_relative "../../support/game_option_form"

class QuestionOptionEditorGame < GameRoomGames::Base
  attr_accessor :reversed
  def id; "question_option_editor_test"; end
  def option_definitions
    [GameRoomGames::OptionDefinition.new(key: "language", label: "Language", kind: :choice, default: "en",
      choices: %w[en pl-PL].map { |value| GameRoomGames::OptionChoice.new(value: value, label: value) })]
  end
  def effective_option_definitions(selected = {})
    language = selected.fetch("language", "en")
    ids = language == "en" ? %w[set.general set.special] : %w[set.ogolny set.wiedzmin]
    ids = ids.reverse if reversed
    super + [
      GameRoomGames::OptionDefinition.new(key: "sets", label: "Question sets", kind: :multiple_values,
        default: ["set.general"], choices: ids.map { |id| GameRoomGames::OptionChoice.new(value: id, label: id) }),
      GameRoomGames::OptionDefinition.new(key: "legacy", label: "Legacy", kind: :multiple_choice, default: 1,
        choices: %w[alpha beta].map { |id| GameRoomGames::OptionChoice.new(value: id, label: id) })
    ]
  end
  def option_editor_changes(previous, current)
    return {} if previous["language"] == current["language"]
    { "sets" => [current["language"] == "en" ? "set.general" : "set.ogolny"] }
  end
end

game = QuestionOptionEditorGame.new
app = EltenGameRoom.allocate
stored = { game.id => { "sets" => ["set.special"], "legacy" => 2 } }
alerts = []
writes = []
app.define_singleton_method(:read_json) { |_path, default:| stored }
app.define_singleton_method(:update_json) { |_path, default:, &block| writes << block.call(Marshal.load(Marshal.dump(stored))) }
app.define_singleton_method(:alert) { |message| alerts << message }

[false, true].each do |reversed|
  game.reversed = reversed
  Form.driver = lambda do |form|
    control = form.fields.find { |field| field.header == "Question sets" }
    legacy = form.fields.find { |field| field.header == "Legacy" }
    assert(control.multiselections == [reversed ? 0 : 1], "saved IDs were interpreted as positions")
    assert(legacy.multiselections == [1], "old mask restoration changed")
    form.accept_button.trigger(:press)
  end
  result = app.send(:configure_game_options, game)
  assert(result["sets"] == ["set.special"] && result["legacy"] == 2, "save changed the selections")
  assert(writes.last.fetch(game.id).fetch("sets") == ["set.special"], "preferences stored a mask instead of IDs")
end

game.reversed = false
Form.driver = lambda do |form|
  control = form.fields.find { |field| field.header == "Question sets" }
  control.deselect_multiselection_indices(control.multiselections)
  form.accept_button.trigger(:press)
end
assert(app.send(:configure_game_options, game)["sets"] == [], "zero selected choices fell back to default")
before_writes = writes.length
Form.driver = ->(form) { form.cancel_button.trigger(:press) }
assert(app.send(:configure_game_options, game) == nil && writes.length == before_writes, "cancel wrote preferences")

Form.driver = lambda do |form|
  fields = form.fields.dup
  control = form.fields.find { |field| field.header == "Question sets" }
  language = form.fields.find { |field| field.header == "Language" }
  form.index = form.fields.index(language)
  language.index = 1
  language.trigger(:move)
  assert(form.fields == fields && form.fields[form.index].equal?(language), "catalogue change rebuilt controls or stole focus")
  assert(control.options == %w[set.ogolny set.wiedzmin], "language did not update checklist choices")
  assert(control.multiselections == [0], "language did not apply the explicit new default")
  assert(form.fields.find { |field| field.header == "Legacy" }.multiselections == [1], "new checklist reset a legacy mask")
  control.select_multiselection_indices([1])
  form.accept_button.trigger(:press)
end
result = app.send(:configure_game_options, game)
assert(result["sets"] == %w[set.ogolny set.wiedzmin], "localized IDs were lost on save")
assert(alerts.empty?, "valid selection raised an alert")

step = 0
Form.driver = lambda do |form|
  control = form.fields.find { |field| field.header == "Question sets" }
  if step == 0
    assert(control.options.last == "Unavailable choice: removed.set", "unavailable saved choice was hidden")
    assert(control.multiselections == [2], "unavailable saved ID was silently cleared")
  else
    assert(alerts.last.to_s.include?("unavailable choice"), "invalid submission did not explain its problem")
    control.deselect_multiselection_indices([2])
    control.select_multiselection_indices([0])
  end
  step += 1
  form.accept_button.trigger(:press)
end
result = app.send(:configure_game_options, game, initial_options: { "sets" => ["removed.set"] })
assert(step == 2 && result["sets"] == ["set.general"], "unavailable selection could not be explicitly replaced")
puts "PASS stable checklist editor: stored IDs, reordering, zero selection, cancel, language refresh, missing resource and legacy controls"
