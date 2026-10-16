require_relative '../support/game_option_form'
require_relative '../support/assertions'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

class CompactOptionGame < GameRoomGames::Base
  def option_definitions
    choices = [GameRoomGames::OptionChoice.new(value: 'first', label: 'First'),
      GameRoomGames::OptionChoice.new(value: 'second', label: 'Second')]
    [GameRoomGames::OptionDefinition.new(key: 'enabled', label: 'Enabled', kind: :boolean, default: true),
      GameRoomGames::OptionDefinition.new(key: 'amount', label: 'Amount', kind: :integer, default: 9),
      GameRoomGames::OptionDefinition.new(key: 'mode', label: 'Mode', kind: :choice, default: 'second', choices: choices),
      GameRoomGames::OptionDefinition.new(key: 'mask', label: 'Mask', kind: :multiple_choice, default: 2, choices: choices),
      GameRoomGames::OptionDefinition.new(key: 'ids', label: 'IDs', kind: :multiple_values, default: ['second'], choices: choices)]
  end

  def normalize_options(values)
    result = super
    option_definitions.each { |item| result.delete(item.key) if result[item.key] == item.default }
    result
  end
end

game = CompactOptionGame.new
editor = GameRoomOptionEditor.new(program: Object.new, defaults: ->(*) { game.default_options },
  remember: ->(*) {}, alert: ->(message) { raise message })
Form.driver = ->(form) do
  fields = form.fields.select { |field| field.respond_to?(:header) }.to_h { |field| [field.header, field] }
  checkbox = fields.fetch('Enabled')
  assert_equal(true, checkbox.checked)
  assert_equal('9', fields.fetch('Amount').text)
  assert_equal(1, fields.fetch('Mode').index)
  assert_equal([1], fields.fetch('Mask').multiselections)
  assert_equal([1], fields.fetch('IDs').multiselections)
  form.accept_button.trigger(:press)
end
assert_equal({}, editor.edit(game, initial_options: {}), 'Opening the editor expanded stored defaults')
Form.driver = ->(form) do
  form.fields.grep(CheckBox).first.checked = false
  form.fields.find { |field| field.respond_to?(:header) && field.header == 'Amount' }.set_text('0')
  form.accept_button.trigger(:press)
end
assert_equal({'enabled' => false, 'amount' => 0}, editor.edit(game, initial_options: {}))
puts 'PASS compact option editor: declared defaults for five control kinds, unchanged storage and explicit false/zero'
