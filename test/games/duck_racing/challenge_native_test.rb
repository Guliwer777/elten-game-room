# Actual native Form/ListBox/EditBox/Button and KeyboardState. Only OS input,
# audio and speech peripherals are replaced, not focus or editing methods.
require_relative '../../support/duck_challenge_native'
include DuckChallengeTest
driver = DuckChallengeNativeDriver.new

model = challenge_state('rhythm')
acknowledge_challenge(model)
surface = challenge_surface(model)
form = driver.form(surface)
driver.frame(form, [[0x0D, true]], held: [0x0D])
begin_action = surface.take_input(form)
assert_equal([{kind: :begin, press_id: 1}], begin_action)
assert(ENGINE.submit(model, seat: 0, action: begin_action.first, now_ms: 10), 'Rhythm did not begin')
surface.present(ENGINE.view(model, seat: 0))
driver.frame(form, [[0x0D, :repeat]], held: [0x0D])
assert_equal([], surface.take_input(form), 'Held Enter leaked across ready/responding')
driver.frame(form, [[0x0D, false]])
driver.frame(form, driver.tap(0x46) + driver.tap(0x4A) + driver.tap(0x46))
actions = surface.take_input(form)
assert_equal(%w[f j f], actions.map { |input| input[:value] }, 'Same-frame rhythm order/tap count was lost')
assert_equal([2, 3, 4], actions.map { |input| input[:press_id] })
driver.frame(form, driver.tap(0x46))
assert_equal('f', surface.take_input(form).first[:value], 'Native consecutive-frame fast tap was lost')
driver.frame(form, [[0x4A, true]], held: [0x4A])
assert_equal('j', surface.take_input(form).first[:value])
3.times do
  driver.frame(form, [[0x4A, :repeat]], held: [0x4A])
  assert_equal([], surface.take_input(form), 'Autorepeat became another rhythm beat')
end
driver.frame(form, [[0x4A, false]])
driver.frame(form, driver.tap(0x46, modifiers: [0x11]))
assert_equal([], surface.take_input(form), 'Released Ctrl+F became a rhythm beat')

# Real Tab/Shift+Tab with a held game key and untouched chat draft.
driver.frame(form, driver.tap(0x09))
assert_equal(form.fields.last, form.fields[form.index], 'Tab did not reach chat')
driver.frame(form, [[0x46, true]], held: [0x46], characters: 'a')
assert_equal([], surface.take_input(form), 'Typing in chat played a rhythm')
chat = form.fields.last
chat_draft = chat.text.dup
driver.frame(form, driver.tap(0x09, modifiers: [0x10]), held: [0x46])
assert_equal(surface.fields.first, form.fields[form.index], 'Shift+Tab did not return to challenge')
assert_equal([], surface.take_input(form), 'Returning inherited the held chat key')
driver.frame(form, [[0x46, :repeat]], held: [0x46])
assert_equal([], surface.take_input(form))
driver.frame(form, [[0x46, false], [0x46, true]], held: [0x46])
assert_equal('f', surface.take_input(form).first[:value], 'Fresh release/repress after chat was lost')
assert_equal(chat_draft, chat.text)
driver.frame(form, [[0x46, false]])

form.show_game_room_help
driver.frame(form, driver.tap(0x4A))
assert_equal([], surface.take_input(form), 'Help key reached the challenge')
driver.frame(form, driver.tap(0x0D))
assert(!form.game_room_background_help?, 'Help did not close with Enter')
assert_equal([], surface.take_input(form), 'Help-closing Enter became an answer')
driver.frame(form, driver.tap(0x4A))
assert_equal('j', surface.take_input(form).first[:value])

# Covered foreign form cannot play the still-attached challenge.
settings = GameRoomUI::Form.new([ListBox.new(['One', 'Two'], quiet: true)], quiet: true)
driver.frame(settings, [[0x46, true]], held: [0x46])
assert_equal([], surface.take_input(form))
surface.fields.first.focus
driver.frame(form, [[0x46, :repeat]], held: [0x46])
assert_equal([], surface.take_input(form))
driver.frame(form, [[0x46, false], [0x46, true]], held: [0x46])
assert_equal('f', surface.take_input(form).first[:value])
driver.frame(form, [[0x46, false]])
surface.deactivate_input

# Navigation belongs to the native list, while confirmation is still guarded
# against repeats. Two ordinary Down updates and Enter choose the third item.
model = challenge_state('rock_paper_scissors')
surface = challenge_surface(model)
form = driver.form(surface)
driver.frame(form, driver.tap(0x28))
driver.frame(form) # The native list debounces identical adjacent-frame presses.
driver.frame(form, driver.tap(0x28) + driver.tap(0x0D))
assert_equal([{kind: :choose, value: 'scissors', press_id: 1}], surface.take_input(form))
assert_equal(2, surface.fields.first.index, 'The adapter changed the native list selection')
surface.deactivate_input

# Real edit control accepts characters, preserves cursor across refreshes,
# and emits the edited answer rather than a stale field value.
model = challenge_state('copy_number')
surface = challenge_surface(model)
form = driver.form(surface)
field = surface.fields.first
number = model[:model][:question][:number].to_s
driver.frame(form, driver.tap(number.getbyte(0)), characters: number)
assert_equal(number, field.text, 'Native editing did not receive characters')
selection = [field.index, field.check]
surface.present(ENGINE.view(model, seat: 0))
assert_equal(selection, [field.index, field.check])
driver.frame(form, driver.tap(0x0D))
answer = surface.take_input(form).first
assert_equal(number, answer[:value])
assert(ENGINE.submit(model, seat: 0, action: answer, now_ms: 20), 'Real edited answer was not accepted by the model')
surface.present(ENGINE.view(model, seat: 0))
assert_equal(field, surface.fields.first, 'Result rebuilt the edit control')
driver.frame(form, driver.tap(0x0D))
assert_equal([], surface.take_input(form), 'Already answered field accepted another answer')
surface.deactivate_input

# A binary-loaded quiz prompt/answer retains its UTF-8 labels in the shared
# list, including when the interface has no translation for the content.
model = challenge_state('quiz')
view = ENGINE.view(model, seat: 0)
view[:question][:prompt] = 'Co oznacza słowo żółw?'.b
view[:question][:choices][0] = 'Żółw'.b
surface = GameSurfaces.build(GameSurfaces::DuckChallengeSpec.new(challenge_id: 'unicode', kind: 'quiz', viewer: 0, view: view))
form = driver.form(surface)
assert_equal('Co oznacza słowo żółw?', surface.fields.first.options.first)
assert_equal('Żółw', surface.fields.first.options[1])
driver.frame(form, driver.tap(0x31))
assert_equal(0, surface.take_input(form).first[:value])
assert(surface.fields.first.options.all? { |label| label.encoding == Encoding::UTF_8 && label.valid_encoding? },
  'Native question rows contain invalid or binary text')
surface.deactivate_input

# Answers retain their original order and input values without spoken ordinals.
# The shared question row is still not an answer; arrows/Enter and 1-4 keep
# selecting the same option, including answers which themselves are numbers.
(0..3).each do |answer_index|
  [:digit, :enter].each do |input|
    model = challenge_state('quiz')
    view = ENGINE.view(model, seat: 0)
    choices = ['21', 'Żółw'.b, '0', 'Łódź'.b]
    view[:question][:choices] = choices
    surface = GameSurfaces.build(GameSurfaces::DuckChallengeSpec.new(
      challenge_id: "plain-#{input}-#{answer_index}", kind: 'quiz', viewer: 0, view: view))
    form = driver.form(surface)
    assert_equal([view[:question][:prompt], '21', 'Żółw', '0', 'Łódź'], surface.fields.first.options)
    assert_equal([0, 1, 2, 3], surface.presentation[:option_keys])
    driver.frame(form, driver.tap(0x0D))
    assert_equal([], surface.take_input(form), 'The prompt row became an answer')
    if input == :enter
      (answer_index + 1).times do
        driver.frame(form)
        driver.frame(form, driver.tap(0x28))
      end
    end
    driver.frame(form)
    driver.frame(form, driver.tap(input == :digit ? 0x31 + answer_index : 0x0D))
    action = surface.take_input(form).first
    assert_equal({kind: :answer, value: answer_index, press_id: 1}, action)
    assert(ENGINE.submit(model, seat: 0, action: action, now_ms: 20),
      'The model rejected an unnumbered quiz answer')
    surface.deactivate_input
  end
end

# Balls display values only. Stable physical positions, not duplicate labels,
# keep the cursor on the same remaining ball after taking 1, 2 or 3 from the front.
(1..3).each do |count|
  model = challenge_state('numbered_balls')
  seat = ENGINE.current_turn(model)
  remaining = ENGINE.view(model, seat: seat).fetch(:remaining)
  selected = (3...remaining.length).find { |index| remaining.first(index).include?(remaining[index]) }
  assert(selected, 'The natural fixture must contain a duplicate ball after the first three')
  assert(remaining.any?(&:negative?), 'The fixture must include negative ball values')
  surface = challenge_surface(model, seat: seat, id: "plain-balls-#{count}")
  form = driver.form(surface)
  field = surface.fields.first
  assert_equal(remaining.map(&:to_s), field.options)
  assert_equal((0...12).to_a, surface.presentation[:option_keys])
  selected.times do
    driver.frame(form)
    driver.frame(form, driver.tap(0x28))
  end
  assert_equal(selected, field.index)
  driver.frame(form, driver.tap(0x30 + count))
  action = surface.take_input(form).first
  assert_equal({kind: :take, value: count, press_id: 1}, action)
  assert(ENGINE.submit(model, seat: seat, action: action, now_ms: 20),
    'The model rejected taking balls from the unnumbered list')
  surface.present(ENGINE.view(model, seat: seat))
  assert_equal(field, surface.fields.first, 'Taking balls rebuilt the control')
  assert_equal(remaining.drop(count).map(&:to_s), field.options)
  assert_equal((count...12).to_a, surface.presentation[:option_keys])
  assert_equal(selected - count, field.index, 'Duplicate values moved the cursor to a different ball')
  assert_equal(remaining[selected].to_s, field.options[field.index])
  surface.deactivate_input
end

# Every non-realtime challenge accepts its native control's command through
# the real dispatcher. Fixture answers may inspect the private model; the
# surface itself receives only Engine.view.
(GameRoomDuckRacing::Challenges::BY_ID.keys - ENGINE::REALTIME).each do |kind|
  model = challenge_state(kind)
  state = model[:model]
  seat = ENGINE.current_turn(model) || 0
  acknowledge_challenge(model, seat: seat) if %w[count_ducks rhythm simon hit_duck].include?(kind)
  surface = challenge_surface(model, seat: seat, id: "native-#{kind}")
  form = driver.form(surface)
  key = 0x0D
  case kind
  when 'guess_number', 'copy_number', 'arithmetic', 'race_question'
    surface.fields.first.set_text(state[:answer].to_s)
  when 'count_ducks'
    surface.fields.first.set_text(state[:private][:count].to_s)
  when 'numbered_balls' then key = 0x32
  when 'simon' then key = 0x30 + state[:private][:sequence].first
  when 'sound_memory' then key = 0x30
  when 'hit_duck' then key = 0x30 + state[:private][:targets].first
  when 'quiz' then key = 0x31 + state[:question][:correct_index]
  end
  if kind == 'sound_order'
    driver.frame(form, driver.tap(0x31, modifiers: [0x10]))
    driver.frame(form)
    driver.frame(form, driver.tap(0x32, modifiers: [0x10]))
  else
    driver.frame(form, driver.tap(key))
  end
  inputs = surface.take_input(form)
  assert_equal(1, inputs.length, "#{kind}: native control emitted no command")
  action_time = kind == 'sound_order' ? ENGINE::ORDER_PREPARATION_MS : 10
  assert(ENGINE.submit(model, seat: seat, action: inputs.first, now_ms: action_time, resources: challenge_resources),
    "#{kind}: model rejected its native control command")
  surface.present(ENGINE.view(model, seat: seat))
  surface.deactivate_input
end

puts 'PASS native Duck controls: ordered taps, repeats, modifiers, phase/focus guards, chat, help, covered form, actual typing and Unicode'
