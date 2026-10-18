# Native keyboard/Form/Button dispatch and the production Pong input reducer
# and engine. No network, real account, hardware key injection or audio output.
require_relative '../../support/background_help_native'
module GameSurfaces
  module ActionEmitter; end
end
require_relative '../../../lib/game_surfaces/pong_surface'
require_relative '../../../lib/axel_pong/client'
require 'json'

class PongModifierBoundaryDriver
  def initialize; @now = 0.0; end
  def state(keys)
    value = "\0" * 256
    keys.each { |key| value.setbyte(key, 0x80) }
    value
  end
  def tick(_form); sample([], []); end
  def sample(events, held)
    @now += 0.016
    EltenAPI::KeyboardState.update(raw_state: state(held), events: events, now: @now,
      pressed_implies_held: false, synthesize_repeats: false)
    $input_frame_serial = $input_frame_serial.to_i + 1
    $keyboard_state_frame_serial = $input_frame_serial
    $keyboard_state_frame_thread = Thread.current
    $activecontrols = []
  end
  def frame(form, events = [], held: [])
    sample(events, held)
    form.update
  end
  def tap(code, modifiers: [])
    modifiers.map { |key| [key, true] } +
      [[code, true, state(modifiers + [code])], [code, false]] +
      modifiers.reverse.map { |key| [key, false] }
  end
end

class PongModifierBoundary
  attr_reader :form, :surface, :field, :chat, :engine, :client, :driver
  def initialize(driver)
    @driver = driver
    EltenAPI::KeyboardState.reset
    spec = GameSurfaces::PongSpec.new(game_id: 'axel_pong', header: 'Playfield',
      players: ['Alice', 'Bob'], viewer: 0, scores: [0, 0], finished: false)
    @surface = GameSurfaces::PongSurface.new(spec)
    @field = surface.fields.first
    @chat = EditBox.new('Chat', text: 'Preserve the draft', quiet: true)
    @form = GameRoomUI::Form.new([field, chat], quiet: true)
    form.game_room_background_help_enabled = true
    @client = GameRoomPong::Client.allocate
    client.instance_variable_set(:@form, form)
    client.instance_variable_set(:@surface, surface)
    @engine = GameRoomPong::PeerEngine.new(side: 0, authority: true, first_server: 0)
    form.focus
  end
  def frame(events = [], held: [], active: true)
    driver.frame(form, events, held: held)
    raw = surface.input(form)
    input = client.send(:playable_input, raw, active: active, moving: active)
    engine.step([input, {}])
    input
  end
end

driver = PongModifierBoundaryDriver.new
$native_tutorial_driver = driver
cases = []
modifiers = [0x10, 0x11, 0x12, 0x5B, 0x5C]
keys = [0x26, 0x20, 0x25, 0x27]
modifiers.each do |modifier|
  keys.each do |code|
    run = PongModifierBoundary.new(driver)
    before = run.field.input.dup
    run.frame(driver.tap(code, modifiers: [modifier]))
    assert(run.field.input == before, "quick #{modifier}+#{code} changed the game input")
    assert(run.engine.turn.zero? && run.engine.paddles == [15.0, 15.0],
      "quick #{modifier}+#{code} served or moved the paddle")
    # ELTEN deliberately debounces identical presses on adjacent input ticks.
    # This is a new physical action after the shortcut, not that debounce.
    run.frame
    run.frame(driver.tap(code))
    expected = [0x26, 0x20].include?(code) ? run.engine.turn == 1 :
      run.engine.paddles[0] == (code == 0x25 ? 14.0 : 16.0)
    assert(expected, "plain fresh key #{code} was lost after a shortcut")
    cases << [modifier, code, 'quick shortcut rejected; plain key works']
  end
end

# The modifier can be pressed or released in a later frame. A fresh arrow
# during a modifier remains a shortcut, not a game key.
modifiers.each do |modifier|
  keys.each do |code|
    run = PongModifierBoundary.new(driver)
    run.frame([[modifier, true]], held: [modifier])
    run.frame([[code, true, driver.state([modifier, code])]], held: [modifier, code])
    assert(run.engine.turn.zero? && run.engine.paddles == [15.0, 15.0],
      "held #{modifier}+#{code} changed gameplay")
    run.frame([[code, false], [modifier, false]])
    assert(run.engine.turn.zero? && run.engine.paddles == [15.0, 15.0],
      "released #{modifier}+#{code} replayed a shortcut")
    run.frame(driver.tap(code))
    assert(run.engine.turn == ([0x26, 0x20].include?(code) ? 1 : 0),
      'fresh game press was lost after held modifier')
    cases << [modifier, code, 'held shortcut rejected']
  end
end

# Host metadata preserves a real press made before a modifier was pressed
# in the same UI frame; the end-of-frame modifier is not its history.
keys.each do |code|
  run = PongModifierBoundary.new(driver)
  run.frame(driver.tap(code) + [[0x11, true]], held: [0x11])
  expected = [0x26, 0x20].include?(code) ? run.engine.turn == 1 :
    run.engine.paddles[0] == (code == 0x25 ? 14.0 : 16.0)
  assert(expected, "later Ctrl erased an earlier unmodified #{code} press")
  cases << [code, 'fresh key before later modifier preserved']
end

# Real Tab/Shift+Tab, help and unrelated settings are never game input.
run = PongModifierBoundary.new(driver)
run.frame(driver.tap(0x09))
assert(run.form.fields[run.form.index].equal?(run.chat), 'Tab did not enter chat')
keys.each { |code| run.frame(driver.tap(code)) }
assert(run.engine.turn.zero? && run.engine.paddles == [15.0, 15.0], 'chat keys reached Pong')
run.frame(driver.tap(0x09, modifiers: [0x10]))
assert(run.form.fields[run.form.index].equal?(run.field), 'Shift+Tab did not return')
run.form.show_game_room_help
keys.each { |code| run.frame(driver.tap(code)) }
assert(run.engine.turn.zero?, 'help keys served')
run.frame(driver.tap(0x0D))
assert(!run.form.game_room_background_help?, 'Enter did not close help')
assert(run.chat.text == 'Preserve the draft', 'game routing damaged the chat draft')
run.frame(driver.tap(0x26))
assert(run.engine.turn == 1, 'fresh post-help serve was lost')

# A stale press accumulated in an inactive field is consumed, not resurrected.
run = PongModifierBoundary.new(driver)
run.frame(driver.tap(0x26), active: false)
run.frame
assert(run.engine.turn.zero?, 'inactive press became a later serve')
run.frame(driver.tap(0x26))
assert(run.engine.turn == 1, 'legitimate post-pause serve failed')

puts JSON.pretty_generate(cases)
puts "PASS Pong native modifiers: #{cases.length} direct cases, chat/help, late modifier, paused input and fresh gameplay"
