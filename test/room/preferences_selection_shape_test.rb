require 'json'
require 'tmpdir'
require_relative '../support/host_source'
require_relative '../support/ui'
require EltenTestHost.file('src/eapi/resources.rb')
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../support/settings_widget'

class SelectionPreferenceApp < EltenGameRoom
  def initialize(runtime)
    @fixture_runtime = runtime
  end

  def read_json(path, default:)
    @fixture_runtime.read_json(path, default: default)
  end
end

GameRoomLocalization.boot(settings: {}, host_language: 'en')
ids = EltenGameRoom::GAME_REGISTRY.ids
legacy = GameRoomPreferences::LEGACY_WIDGET_GAME_IDS
assert(ids.include?('uno') && ids.include?('makao') && (ids - legacy).any?, 'incomplete catalogue fixture')
cases = 0

Dir.mktmpdir('game-selection-preferences-') do |directory|
  runtime = Programs::Runtime.allocate
  runtime.instance_variable_set(:@json_file_monitors_guard, Mutex.new)
  runtime.instance_variable_set(:@json_file_monitors, {})
  runtime.define_singleton_method(:data_path) do |name|
    path = File.expand_path(name, directory)
    raise 'outside owned fixture' unless path.start_with?(directory.tr('\\', '/') + '/')
    FileUtils.mkdir_p(File.dirname(path))
    path
  end
  writes = 0
  runtime.define_singleton_method(:write_json) do |name, value|
    writes += 1
    super(name, value)
  end

  check = lambda do |stored, key, expected|
    assert(runtime.write_json('settings.json', stored), 'native fixture write failed')
    loaded = runtime.read_json('settings.json')
    assert(loaded == stored, 'native JSON roundtrip changed settings')
    bytes = File.binread(runtime.data_path('settings.json'))
    original = Marshal.dump(loaded)
    before = writes
    app = SelectionPreferenceApp.new(runtime)
    2.times do
      result = app.send(:game_room_settings, reload: true)
      assert(result.fetch(key) == expected, "wrong selection for #{key}: #{stored.inspect}")
      assert((ids - result.fetch(key.sub('_games', '_known_games'))).empty?, 'migration lost known catalogue')
      other = key == 'lobby_games' ? 'widget_games' : 'lobby_games'
      assert(result.fetch(other) == ['makao'], 'normalizing one selection changed the other channel')
      assert(result['sound_volumes']['all'] == 43 && result['sentinel'] == 'keep', 'unrelated settings changed')
      assert(result['widget_enabled'] == false && result['announce_player_joined'] == false,
        'normalization reenabled a disabled widget or announcement')
      assert(GameRoomPreferences.widget_enabled?(loaded, ids) == false, 'widget consumer lost disabled setting')
      assert(!GameRoomPreferences.lobby_announcement_enabled?(loaded, :joined, 'uno', ids),
        'lobby consumer ignored disabled announcement')
      if key == 'widget_games'
        assert(GameRoomPreferences.widget_game_enabled?(loaded, 'uno', ids) == expected.include?('uno'),
          'widget consumer disagreed with normalized selection')
      else
        assert(GameRoomPreferences.lobby_announcement_enabled?(loaded, :created, 'uno', ids) == expected.include?('uno'),
          'lobby consumer disagreed with normalized selection')
      end
    end
    assert(Marshal.dump(loaded) == original, 'normalization mutated input settings')
    assert(writes == before && File.binread(runtime.data_path('settings.json')) == bytes,
      'reading preferences saved, reset or repaired the file')
    cases += 1
  end

  %w[lobby_games widget_games].each do |key|
    known_key = key.sub('_games', '_known_games')
    other = key == 'lobby_games' ? 'widget_games' : 'lobby_games'
    base = {other => ['makao'], other.sub('_games', '_known_games') => ids,
      'widget_enabled' => false, 'announce_player_joined' => false,
      'sound_volumes' => {'all' => 43}, 'sentinel' => 'keep'}
    # Missing means the default. A present malformed value means no selected
    # known games, just like the existing nil/object and explicit empty cases.
    # The independently approved migration still enables newly added games.
    [nil, ids, false].each do |known|
      stored = base.dup
      stored[known_key] = known unless known.nil?
      check.call(stored, key, ids)
      [false, true, 0, -4, 4.5, '', 'uno', nil, {}, {'uno' => true}, [],
        ['uno'], ['makao', 'uno', 'uno', 'unknown'], [nil, false, 7, [], {}, 'uno']].each do |raw|
        selected = raw.is_a?(Array) ? raw.map(&:to_s) : []
        previous = known.is_a?(Array) ? known : legacy
        expected = ids.select { |id| selected.include?(id) || !previous.include?(id) }
        check.call(stored.merge(key => raw), key, expected)
      end
    end
    # Saving an explicit empty choice with the known catalogue remains empty;
    # a later new ID is enabled once, not confused with an earlier opt-out.
    empty = GameRoomPreferences.normalize(base.merge(key => [], known_key => ids), ids)
    assert(empty[key].empty?, 'explicit current empty selection was reset')
    later = GameRoomPreferences.normalize(empty, ids + ['future_game'])
    assert(later[key] == ['future_game'], 'future migration reset previous opt-outs')
    later[key] = []
    assert(GameRoomPreferences.normalize(later, ids + ['future_game'])[key].empty?, 'later opt-out was undone')
  end
end

puts "Game selection preferences: #{cases} native JSON/application read cases, migration and pure reads OK"
