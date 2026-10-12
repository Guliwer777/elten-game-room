# Real native ListBox/Form and keyboard events, including the character
# stream which list prefix-search uses independently of physical key edges.
require_relative '../../support/duck_challenge_native'
include DuckChallengeTest
driver = DuckChallengeNativeDriver.new

(0..9).each do |digit|
  [true, false].each do |own_turn|
    model = challenge_state('numbered_balls')
    turn = ENGINE.current_turn(model)
    surface = challenge_surface(model, seat: own_turn ? turn : 1 - turn,
      id: "balls-digit-#{digit}-#{own_turn}")
    form = driver.form(surface)
    field = surface.fields.first
    # GameRoomShortcutBindings replaces this set when binding table shortcuts.
    field.game_shortcut_signatures = [['i', []], ['c', []]]
    field.game_shortcut_signatures = []
    target = field.options.index { |label| label.start_with?(digit.to_s) }
    selected = target == 0 ? 1 : 0
    selected.times { driver.frame(form, driver.tap(0x28)) }
    assert_equal(selected, field.index)
    driver.frame(form)
    driver.frame(form, driver.tap(0x30 + digit), characters: digit.to_s)
    assert_equal(selected, field.index, "Digit #{digit} moved the ball cursor (own turn: #{own_turn})")
    expected = own_turn && digit.between?(1, 3) ? [{kind: :take, value: digit, press_id: 1}] : []
    assert_equal(expected, surface.take_input(form))

    driver.frame(form)
    driver.frame(form, driver.tap(0x28))
    assert_equal(selected + 1, field.index, 'Down no longer browses balls')
    driver.frame(form)
    driver.frame(form, driver.tap(0x26))
    assert_equal(selected, field.index, 'Up no longer browses balls')

    # Digits still belong to the chat editor when it has focus.
    driver.frame(form, driver.tap(0x09))
    chat = form.fields.last
    assert_equal(chat, form.fields[form.index])
    chat.set_text('')
    driver.frame(form, driver.tap(0x30 + digit), characters: digit.to_s)
    assert_equal(digit.to_s, chat.text)
    assert_equal([], surface.take_input(form), 'A chat digit took balls')
    surface.deactivate_input
  end
end

model = challenge_state('numbered_balls')
surface = challenge_surface(model, seat: ENGINE.current_turn(model))
form = driver.form(surface)
field = surface.fields.first
field.game_shortcut_signatures = []
[0x10, 0x11, 0x12].each do |modifier|
  driver.frame(form)
  driver.frame(form, driver.tap(0x31, modifiers: [modifier]), characters: '1')
  assert_equal(0, field.index, 'A modified digit moved the ball cursor')
  assert_equal([], surface.take_input(form), 'A modified digit took balls')
end
driver.frame(form)
driver.frame(form, [[0x31, true]], held: [0x31], characters: '1')
assert_equal([1], surface.take_input(form).map { |action| action[:value] })
3.times do
  driver.frame(form, [[0x31, :repeat]], held: [0x31], characters: '1')
  assert_equal(0, field.index)
  assert_equal([], surface.take_input(form), 'Autorepeat took extra balls')
end
surface.deactivate_input
puts 'PASS numbered balls native digits, shortcut rebinding, arrows, chat, modifiers and repeats'
