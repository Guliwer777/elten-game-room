require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_screen'
require_relative '../../../lib/game_shortcuts'

include DuckGameAdapterTest

class DuckMapBrowseDriver < BackgroundHelpNativeDriver
  attr_reader :indices, :options

  def initialize(keys)
    super()
    @keys, @indices = keys, []
  end

  def tick(form)
    if form.is_a?(GameRoomUI::Form) && form.instance_variable_get(:@wait)
      @root ||= form
      raise 'Map opened an unexpected form' unless form.equal?(@root)
      @indices << form.fields.first.index
      @options = form.fields.first.options
    end
    super
  end
end

def open_map(shortcut, keys: [[], [0x1b]])
  EltenAPI::KeyboardState.reset
  SpeechOutput.reset
  $native_tutorial_driver = DuckMapBrowseDriver.new(keys)
  screen = GameScreen.allocate
  assert_equal(nil, screen.send(:activate_game_shortcut, shortcut))
  $native_tutorial_driver
end

h = Harness.new
h.start
replay = h.replay
game = h.game

# Every square, including later laps and the boundary between laps, is
# selected by value. The complete track retains its ordinary 1..30 order.
(0..62).each do |progress|
  replay.state[:race][:racers][0][:progress] = progress
  saved = Marshal.dump(replay.state)
  shortcut = game.custom_game_shortcuts(replay, 'Alice').find { |key| key.key == 'v' }
  square = progress % 30 + 1
  assert_equal(square, shortcut.default_value)
  assert_equal((1..30).to_a, shortcut.choices.map(&:value))
  driver = open_map(shortcut)
  assert_equal(square - 1, driver.indices.first)
  assert_equal(shortcut.choices.map(&:label), driver.options)
  assert(SpeechOutput.calls.any? { |text, *_| text.include?(shortcut.choices[square - 1].label) },
    'The native map did not read its selected square on opening')
  assert_equal(saved, Marshal.dump(replay.state), 'Browsing changed the race')
end

# The selection is personal, not the current actor's position. Spectators
# still open at the beginning; no old selection leaks between viewers.
replay.state[:race][:racers][1][:progress] = 46
{'Bob' => 16, 'Observer' => 0}.each do |viewer, index|
  shortcut = game.custom_game_shortcuts(replay, viewer).find { |key| key.key == 'v' }
  assert_equal(index, open_map(shortcut).indices.first)
end

replay.state[:race][:racers][0][:progress] = 44
shortcut = game.custom_game_shortcuts(replay, 'Alice').find { |key| key.key == 'v' }
driver = open_map(shortcut, keys: [[], [0x28], [], [0x26], [], [0x24], [], [0x23], [], [0x1b]])
assert_equal([14, 15, 14, 0, 29], driver.indices.chunk(&:itself).map(&:first),
  'Arrows/Home/End no longer follow the normal track order')

# Existing browse shortcuts without a default keep the first row, as does
# an out-of-date value. Feature-built shortcuts preserve an explicit value.
choices = shortcut.choices
[nil, 999, 18].each do |default|
  source = Object.new
  source.define_singleton_method(:shortcut_feature_data) do |*_args|
    {kind: :browse, prompt: 'Track', choices: choices, default_value: default}
  end
  built = GameRoomShortcuts.build(source, [:round_summary], nil, 'Alice').first
  assert_equal(default == 18 ? 17 : 0, open_map(built).indices.first)
end

puts 'PASS Duck map: native dialog, every square and lap boundary, personal position, observer, arrows/Home/End, Escape, default browse compatibility, immutable race'
