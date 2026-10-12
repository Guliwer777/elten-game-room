# Exercise the real host controls; do not recreate list navigation in a stub.
require_relative '../../support/duck_challenge_native'

include DuckChallengeTest

$duck_list_sounds = []
def play_sound(name, **_options)
  $duck_list_sounds << name
end

def navigate_native(field, events)
  driver = DuckChallengeNativeDriver.new
  form = GameRoomUI::Form.new([field], quiet: true)
  form.focus
  $duck_list_sounds.clear
  borders = []
  field.on(:border) { |index| borders << index }
  rows = events.map do |codes|
    driver.frame(form, codes.flat_map { |code| driver.tap(code) })
    [field.index, $duck_list_sounds.dup, borders.dup]
  end
  [rows, driver, form]
end

original_listtype = Configuration.listtype
begin
  [:standard, :circular].each do |listtype|
    Configuration.listtype = listtype
    %w[rock_paper_scissors risky_dice numbered_balls quiz].each do |kind|
      model = challenge_state(kind)
      surface = challenge_surface(model)
      field = surface.fields.first
      assert(!surface.native_command?(:key_up) && !surface.native_command?(:key_down),
        "#{kind} still intercepts ordinary list navigation")
      plain = GameSurfaces::RefreshAwareListBox.new(field.options.dup, header: field.header, quiet: true)
      # Borders, holds handled by the host, Home/End, Page keys and multiple
      # same-frame arrows must all have the same semantics as an ordinary list.
      events = [[0x26], [0x28], [0x28, 0x28], [0x23], [0x28], [0x24], [0x21], [0x22], [0x26]]
      expected, = navigate_native(plain, events)
      actual, = navigate_native(field, events)
      assert_equal(expected, actual, "#{kind}/#{listtype}: navigation, list sounds or borders differ from the host")
      surface.deactivate_input
    end
  end
ensure
  Configuration.listtype = original_listtype
end

driver = DuckChallengeNativeDriver.new
model = challenge_state('quiz')
surface = challenge_surface(model)
form = driver.form(surface)
field = surface.fields.first
view = ENGINE.view(model, seat: 0)
assert_equal(['', 5, view[:question][:prompt], 0], [field.header, field.options.length, field.options.first, field.index])
assert(surface.instance_variable_get(:@question_surface).is_a?(GameSurfaces::QuestionSurface),
  'Duck quiz is not using the shared question surface')
driver.frame(form, driver.tap(0x0D))
assert_equal([], surface.take_input(form), 'Enter on the question row selected an answer')
driver.frame(form, driver.tap(0x28))
driver.frame(form, driver.tap(0x0D))
assert_equal([{kind: :answer, value: 0, press_id: 1}], surface.take_input(form))
driver.frame(form, driver.tap(0x23))
before = [field.object_id, field.index, field.options.dup, field.header]
surface.present(view)
assert_equal(before, [surface.fields.first.object_id, field.index, field.options, field.header],
  'A refresh reset the standard question layout or cursor')
driver.frame(form, driver.tap(0x0D))
assert_equal([{kind: :answer, value: 3, press_id: 2}], surface.take_input(form))
driver.frame(form, driver.tap(0x32))
assert_equal([{kind: :answer, value: 1, press_id: 3}], surface.take_input(form), 'Direct digits acquired the question-row offset')
surface.present(view.merge(own: {done: true}))
driver.frame(form, driver.tap(0x31))
assert_equal([], surface.take_input(form), 'A finished quiz accepted a second answer')
surface.deactivate_input

# Native Up/Down repeat now works just as in other games; the retained
# challenge edge filter still prevents holding Enter from submitting twice.
model = challenge_state('rock_paper_scissors')
surface = challenge_surface(model)
form = driver.form(surface)
driver.frame(form, [[0x28, true]], held: [0x28])
driver.frame(form, [], held: [0x28])
driver.frame(form, [[0x28, :repeat]], held: [0x28])
assert_equal(2, surface.fields.first.index, 'Holding Down no longer navigates the native list')
driver.frame(form, [[0x28, false], [0x0D, true]], held: [0x0D])
assert_equal([{kind: :choose, value: 'scissors', press_id: 1}], surface.take_input(form))
driver.frame(form, [[0x0D, :repeat]], held: [0x0D])
assert_equal([], surface.take_input(form))
surface.deactivate_input

puts 'PASS shared Duck list framework: five list kinds, both host list modes, native boundaries/navigation sounds, question row, answer mapping, refresh and repeats'
