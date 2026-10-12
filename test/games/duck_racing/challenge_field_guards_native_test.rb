require_relative '../../support/duck_challenge_native'

include DuckChallengeTest
driver = DuckChallengeNativeDriver.new

# Button's native focus has no spk flag. One quiet focus must still register
# the input target; a later explicit focus must read the button as usual.
model = challenge_state('dice_duel')
surface = challenge_surface(model, seat: ENGINE.current_turn(model))
form = driver.form(surface)
button = surface.fields.first
button.suppress_next_focus!
SpeechOutput.reset
button.focus(0, form.fields.length)
assert_equal([], SpeechOutput.calls, 'One-off button focus repeated the initial announcement')
assert_equal(button, GameRoomDuckRacing::Keyboard.active_field)
button.focus(0, form.fields.length)
assert_equal(1, SpeechOutput.calls.length, 'The next deliberate button focus remained muted')
assert(SpeechOutput.calls.first.first.start_with?(button.label), 'Manual focus did not read the button')
button.suppress_next_focus!
button.clear_suppressed_focus!
button.focus(0, form.fields.length)
assert_equal(2, SpeechOutput.calls.length, 'Quiet-wait reset did not restore normal focus')
driver.frame(form, driver.tap(0x0D))
assert_equal([{kind: :roll, press_id: 1}], surface.take_input(form))
surface.deactivate_input

# A player waiting for their numbered-balls turn, and a spectator, can
# inspect the row without being allowed to take any balls.
model = challenge_state('numbered_balls')
turn = ENGINE.view(model, seat: 0)[:turn_seat]
other = 1 - turn
before = Marshal.dump(model)
[other, nil].each do |viewer|
  surface = challenge_surface(model, seat: viewer)
  form = driver.form(surface)
  field = surface.fields.first
  assert_equal(false, surface.presentation[:enabled])
  2.times do
    driver.frame(form, driver.tap(0x28))
    driver.frame(form)
  end
  assert_equal(2, field.index, 'Waiting/observing blocked inspection of numbered balls')
  driver.frame(form, driver.tap(0x32))
  assert_equal([], surface.take_input(form), 'Inspection granted permission to take balls')
  driver.frame(form, driver.tap(0x26))
  assert_equal(1, field.index)
  assert_equal(before, Marshal.dump(model), 'Browsing changed the challenge model')
  surface.deactivate_input
end

surface = challenge_surface(model, seat: turn)
form = driver.form(surface)
driver.frame(form, driver.tap(0x33))
assert_equal([{kind: :take, value: 3, press_id: 1}], surface.take_input(form), 'The active player lost normal input')
empty = ENGINE.view(model, seat: turn)
empty[:remaining], empty[:finished] = [], true
surface.present(empty)
driver.frame(form, driver.tap(0x28))
assert_equal([], surface.take_input(form))
assert_equal(0, surface.fields.first.index, 'Empty balls moved the cursor out of range')
surface.deactivate_input
$activecontrols = []

puts 'PASS native challenge fields: one-off Button speech suppression retains focus/input; numbered-ball inspection outside turn cannot play or mutate the model'
