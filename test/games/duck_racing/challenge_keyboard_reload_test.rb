require_relative '../../support/duck_challenge_native'
require EltenTestHost.file('src/eapi/program.rb')
include DuckChallengeTest

DuckReloadManifest = Struct.new(:namespace_name)
DuckReloadRuntime = Struct.new(:manifest, :namespace)

def load_duck_keyboard
  runtime = DuckReloadRuntime.new(DuckReloadManifest.new('DuckKeyboardReloadTest'))
  backend = Programs::Execution::RuntimeBackend.new(runtime)
  runtime.namespace = backend.namespace
  runtime.namespace.define_singleton_method(:require_relative) do |name|
    raise "Unexpected dependency #{name}" unless name == '../host_bridge'
    true
  end
  %w[lib/host_bridge.rb lib/duck_racing/keyboard.rb].each do |path|
    full = File.expand_path("../../../#{path}", __dir__)
    backend.evaluate(File.binread(full), full)
  end
  [backend, runtime.namespace.const_get(:GameRoomDuckRacing).const_get(:Keyboard)]
end

driver = DuckChallengeNativeDriver.new
driver.snapshot([], [])
audio_field = GameSurfaces::AudioBallField.new('Existing Audio Ball')
audio_field.focus
audio = GameRoomAudioBall::Keyboard
assert(audio.active?, 'Audio Ball observer was not active')

target = EltenAPI::KeyboardState.singleton_class
backend, old = load_duck_keyboard
field = Object.new
def field.duck_keys; [0x31, 0x32]; end
old.activate(field)
depth = target.ancestors.length
10.times { old.install }
assert_equal(depth, target.ancestors.length, 'Repeated install accumulated hooks')
result = driver.snapshot(driver.tap(0x31) + driver.tap(0x26), [])
assert_equal([0x31], old.frame(field).presses.map(&:first))
assert_equal([0x26], audio.frame.map(&:first))
assert_equal(result, EltenAPI::KeyboardState.current, 'Hook replaced the native result')

# Actual runtime namespace disposal/replacement, not merely resetting a flag.
backend.dispose
old.define_singleton_method(:capture) { |*| raise 'Retired Duck observer was called' }
assert(!EltenPrograms.const_defined?(:DuckKeyboardReloadTest, false), 'Old app namespace remained installed')
backend, current = load_duck_keyboard
new_field = Object.new
def new_field.duck_keys; [0x31, 0x32]; end
current.activate(new_field)
assert_equal(depth, target.ancestors.length, 'Reload stacked another wrapper')
result = driver.snapshot(driver.tap(0x32) + driver.tap(0x26), [])
assert_equal([0x32], current.frame(new_field).presses.map(&:first))
assert(current.frame(new_field).is_a?(current::Frame), 'Frame retained the old app namespace')
assert_equal([0x26], audio.frame.map(&:first), 'Duck reload disrupted Audio Ball capture')
assert_equal(result, EltenAPI::KeyboardState.current)

# Switching controls and suppressing held keys leaves both APIs intact.
driver.snapshot([[0x31, true]], [0x31])
current.clear(new_field)
driver.snapshot([[0x31, :repeat]], [0x31])
assert_equal([], current.frame(new_field).presses)
driver.snapshot([[0x31, false], [0x31, true]], [0x31])
assert_equal([0x31], current.frame(new_field).presses.map(&:first))
assert_equal(true, EltenAPI::KeyboardState.suppress_held_until_release)
driver.snapshot([[0x31, :repeat]], [0x31])
assert_equal([], current.frame(new_field).presses)
driver.snapshot([[0x31, false], [0x31, true]], [0x31])
assert_equal([0x31], current.frame(new_field).presses.map(&:first))
current.deactivate(new_field)
assert_equal(nil, current.frame(new_field))
audio_field.blur
assert(!audio.active?, 'Audio Ball blur failed after coexisting hooks')

counter = 0
current.define_singleton_method(:capture) { |*| counter += 1 }
10.times { driver.snapshot(driver.tap(0x31), []) }
assert_equal(0, counter, 'Duck hook captured keys with no focused challenge')
backend.dispose
puts 'PASS Duck native keyboard: opt-in capture, Audio Ball coexistence, one reloadable bridge, native result identity and held-key suppression'
