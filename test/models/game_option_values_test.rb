require_relative '../support/assertions'
require_relative '../../games/base'
require_relative '../../lib/game_option_values'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

definition = ->(key, kind, default, choices = []) do
  GameRoomGames::OptionDefinition.new(key: key, label: key, kind: kind, default: default,
    choices: choices.map { |value, label| GameRoomGames::OptionChoice.new(value: value, label: label) })
end
definitions = [
  definition.call('enabled', :boolean, true),
  definition.call('time', :integer, 9),
  definition.call('mode', :choice, 2, [[1, 'First'], [2, 'Second']]),
  definition.call('mask', :multiple_choice, 2, [['a', 'First'], ['b', 'Second']]),
  definition.call('ids', :multiple_values, ['b'], [['a', 'First'], ['b', 'Second']])
]
definitions[1].summary_unit = :seconds
expected = ['Yes', '9 seconds', 'Second', 'Second', 'Second']
definitions.each_with_index do |item, index|
  assert_equal(item.default, GameRoomOptionValues.read(item, {}))
  assert_equal(expected[index], GameRoomOptionValues.format(item, GameRoomOptionValues.read(item, {})))
  assert(GameRoomOptionValues.valid?(item, item.default))
  assert(!GameRoomOptionValues.valid?(item, nil))
  assert_equal(nil, GameRoomOptionValues.read(item, {item.key => nil}), 'Explicit nil was repaired')
end
assert_equal(false, GameRoomOptionValues.read(definitions[0], {'enabled' => false}))
assert_equal(0, GameRoomOptionValues.read(definitions[1], {'time' => 0}))
assert_equal(false, GameRoomOptionValues.read(definitions[0], {enabled: false}))
assert_equal(false, GameRoomOptionValues.read(definitions[0], {'enabled' => false, enabled: true}))
assert(!GameRoomOptionValues.valid?(definitions[0], 'false'))
assert(!GameRoomOptionValues.valid?(definitions[1], 9.0))
assert(!GameRoomOptionValues.valid?(definitions[2], '2'))
assert(!GameRoomOptionValues.valid?(definitions[3], -1))
assert(!GameRoomOptionValues.valid?(definitions[3], 4))
assert(!GameRoomOptionValues.valid?(definitions[4], ['unknown']))
assert_equal('None', GameRoomOptionValues.format(definitions[3], 0))
assert_equal('None', GameRoomOptionValues.format(definitions[4], []))

# A future compact game must work without any identifier-specific exceptions.
game = Class.new(GameRoomGames::Base).new
game.define_singleton_method(:effective_option_definitions) { |*| definitions }
before = Marshal.dump(definitions)
assert_equal(['enabled: Yes', 'time: 9 seconds', 'mode: Second', 'mask: Second', 'ids: Second'],
  GameRoomOptionValues.lines(game, {}))
assert_equal("enabled\r\n\r\ntime: 9 seconds\r\n\r\nmode: Second\r\n\r\nmask: Second\r\n\r\nids: Second", game.rules_options_text({}))
assert_equal(before, Marshal.dump(definitions), 'Formatting changed defaults or labels')
puts 'PASS shared option definitions: all five kinds, compact defaults, false/zero/nil, strict values and a future game without special cases'
