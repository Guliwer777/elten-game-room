# Independent RT-1 verification: native keyboard state, Form, EditBox, Menu,
# production Pong input filtering and PeerEngine. No live account or hardware.
require_relative '../../support/background_help_native'
require File.join(EltenTestHost.root, 'src/ui/controls/menu')
module GameSurfaces
  module ActionEmitter; end
end
require_relative '../../../lib/game_surfaces/pong_surface'
require_relative '../../../lib/axel_pong/client'

class PongShortcutIsolationInput
  attr_accessor :menu_frames, :during_menu
  def initialize
    @time = 0.0
  end
  def bits(keys)
    value = "\0" * 256
    keys.each { |code| value.setbyte(code, 0x80) }
    value
  end
  def sample(events = [], held = [])
    @time += 0.02
    EltenAPI::KeyboardState.update(raw_state: bits(held), events: events, now: @time,
      pressed_implies_held: false, synthesize_repeats: false)
    $input_frame_serial = $input_frame_serial.to_i + 1
    $keyboard_state_frame_serial = $input_frame_serial
    $keyboard_state_frame_thread = Thread.current
    $activecontrols = []
  end
  def tap(code, mods = [])
    mods.map { |modifier| [modifier, true] } +
      [[code, true, bits(mods + [code])], [code, false]] +
      mods.reverse.map { |modifier| [modifier, false] }
  end
  def tick(_control)
    if @menu_frames
      frame = @menu_frames.shift
      raise 'Native menu did not finish the finite input stream' unless frame
      sample(*frame)
      @during_menu&.call
    else
      sample
    end
  end
end

class PongShortcutIsolationFixture
  attr_reader :driver, :surface, :field, :chat, :form, :client, :engine
  def initialize(driver)
    @driver = driver
    EltenAPI::KeyboardState.reset
    spec = GameSurfaces::PongSpec.new(game_id: 'axel_pong', header: 'Playfield',
      players: %w[Alice Bob], viewer: 0, scores: [0, 0], finished: false)
    @surface = GameSurfaces::PongSurface.new(spec)
    @field = @surface.fields.first
    @chat = EditBox.new('Chat', text: 'one two three', quiet: true)
    @form = GameRoomUI::Form.new([@field, @chat], quiet: true)
    @client = GameRoomPong::Client.allocate
    @client.instance_variable_set(:@surface, @surface)
    @client.instance_variable_set(:@form, @form)
    @engine = GameRoomPong::PeerEngine.new(side: 0, authority: true, first_server: 0)
    @form.focus
  end
  def consume
    raw = @surface.input(@form)
    filtered = @client.send(:playable_input, raw, active: true, moving: true)
    @engine.step([filtered, {}])
    filtered
  end
  def frame(events = [], held = [])
    @driver.sample(events, held)
    @form.update
    consume
  end
  def assert_idle(label)
    assert(@engine.turn.zero? && @engine.paddles == [15.0, 15.0], label)
  end
end

driver = PongShortcutIsolationInput.new
$native_tutorial_driver = driver
cases = 0
# Left/right physical Ctrl are distinct native keys. The host helper accepts
# them even when only the side-specific code is present in the press snapshot.
[[0xA2], [0xA3], [0xA3, 0x10], [0x11, 0x12], [0x5B, 0x10], [0x5C]].each do |mods|
  [0x25, 0x27, 0x26, 0x20].each do |key|
    fixture = PongShortcutIsolationFixture.new(driver)
    original = fixture.field.input.dup
    fixture.frame(driver.tap(key, mods))
    assert(fixture.field.input == original, "native modifier snapshot #{mods.inspect}/#{key} became gameplay")
    fixture.assert_idle('shortcut moved or served')
    fixture.frame
    fixture.frame(driver.tap(key))
    if [0x26, 0x20].include?(key)
      assert(fixture.engine.turn == 1, 'fresh ordinary serve lost after a shortcut')
    else
      expected = key == 0x25 ? 14.0 : 16.0
      assert(fixture.engine.paddles[0] == expected, 'fresh ordinary paddle step lost after shortcut')
    end
    cases += 1
  end
end

# Holding the ordinary arrow retains continuous movement without inventing
# extra DOWN edges. Adding Ctrl suspends it; a later genuine tap still works.
[0x25, 0x27].each do |key|
  fixture = PongShortcutIsolationFixture.new(driver)
  fixture.frame([[key, true, driver.bits([key])]], [key])
  9.times { fixture.frame([], [key]) }
  count = key == 0x25 ? 'left_press' : 'right_press'
  assert(fixture.field.input[count] == 1, 'a held arrow created additional press edges')
  assert((fixture.engine.paddles[0] - 15).abs > 1, 'ordinary held-arrow repeat stopped')
  position = fixture.engine.paddles[0]
  fixture.frame([[0xA3, true]], [key, 0xA3])
  4.times { fixture.frame([], [key, 0xA3]) }
  assert(fixture.engine.paddles[0] == position, 'held physical Ctrl did not suspend movement')
  fixture.frame([[key, false], [0xA3, false]])
  fixture.frame
  fixture.frame(driver.tap(key))
  assert(fixture.field.input[count] == 2, 'ordinary new edge was lost after held Ctrl')
end

# Native chat navigation uses the same press-time modifier contract. Its
# Ctrl+Left must move the text caret, never the paddle, and preserve the draft.
fixture = PongShortcutIsolationFixture.new(driver)
fixture.frame(driver.tap(0x09))
assert(fixture.form.fields[fixture.form.index].equal?(fixture.chat), 'native Tab did not focus chat')
fixture.chat.index = fixture.chat.text.length
fixture.chat.check = fixture.chat.index
fixture.frame(driver.tap(0x25, [0x11]))
assert(fixture.chat.index < fixture.chat.text.length, 'native Ctrl+Left did not navigate the draft')
fixture.assert_idle('chat shortcut reached the game')
fixture.frame
fixture.frame([[0x10, true], [0x09, true, driver.bits([0x10, 0x09])]], [0x10, 0x09])
assert(fixture.form.fields[fixture.form.index].equal?(fixture.field), 'native Shift+Tab did not focus the field')
fixture.frame([[0x09, false], [0x10, false]])
fixture.assert_idle('returning from chat caused gameplay')
assert(fixture.chat.text == 'one two three', 'shortcut isolation changed the draft')

# Use the actual native Menu, not a simulated selected menu row. During its
# wait the active control is never the playfield; closing it with Escape
# cannot replay its arrows or Space as a later serve.
menu = EltenAPI::Controls.const_get(:Menu).new('Options')
menu.option('First') {}
menu.option('Second') {}
before = fixture.field.input.dup
driver.menu_frames = [
  [driver.tap(0x28), []],
  [driver.tap(0x26, [0x11]), []],
  [[], []],
  [driver.tap(0x27), []],
  [[], []],
  [driver.tap(0x20), []],
  [driver.tap(0x1B), []]
]
driver.during_menu = -> { fixture.consume; fixture.assert_idle('menu navigation reached Pong') }
menu.open
assert(driver.menu_frames.empty?, 'menu did not process all expected native inputs')
driver.menu_frames = driver.during_menu = nil
assert(fixture.field.input == before, 'menu input changed gameplay counters')
fixture.form.focus
fixture.frame
fixture.assert_idle('closing native menu served or moved')
fixture.frame(driver.tap(0x20))
assert(fixture.engine.turn == 1, 'fresh Space serve lost after native menu')

puts "PASS independent Pong input: #{cases} side/combined modifier taps, held movement, native chat caret and menu isolation"
