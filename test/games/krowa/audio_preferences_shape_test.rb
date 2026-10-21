require 'json'
require 'tmpdir'
require_relative '../../support/host_source'
require_relative '../../support/ui'
require EltenTestHost.file('src/eapi/resources.rb')
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../../support/krowa'
require_relative '../../../games/krowa_support/client'

# Exercise the real JSON reader and the constructor which consumes preferences
# before KrowaClient#start can handle service failures. No live profile is used.
Dir.mktmpdir('krowa-audio-preferences-') do |directory|
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
  refuse_write = false
  runtime.define_singleton_method(:write_json) do |name, data|
    writes += 1
    refuse_write ? false : super(name, data)
  end

  game = KrowaTestGame.new.game
  name = 'game_audio/krowa.json'
  fresh = GameRoomGames::KrowaClient.new(runtime, game)
  fresh_audio = fresh.instance_variable_get(:@audio)
  assert(fresh_audio.settings['effects'] == true, 'new Krowa profile disables sound effects')
  assert(fresh_audio.settings['music'] == false, 'enabling effects also enabled music')
  assert(!File.exist?(runtime.data_path(name)) && writes.zero?, 'reading defaults created a preference file')
  fresh.close
  cases = 0
  check = lambda do |stored, expected|
    assert(runtime.write_json(name, stored), 'fixture JSON write failed')
    assert(runtime.read_json(name, default: {}) == stored, 'native JSON roundtrip changed input')
    bytes = File.binread(runtime.data_path(name))
    before = writes
    client = GameRoomGames::KrowaClient.new(runtime, game)
    audio = client.instance_variable_get(:@audio)
    assert(audio.settings == expected, "wrong normalized preferences: #{stored.inspect}")
    assert(File.binread(runtime.data_path(name)) == bytes && writes == before,
      'loading normalized preferences rewrote or reset the saved file')
    client.close
    cases += 1
    audio
  end

  %w[music_volume effects_volume].each do |key|
    other = key == 'music_volume' ? 'effects_volume' : 'music_volume'
    [false, true, [], {}, ['40'], {'value' => 40}].each do |raw|
      check.call({'music' => true, 'effects' => false, key => raw, other => 23},
        GameRoomAudio::DEFAULTS.merge('music' => true, 'effects' => false, key => GameRoomAudio::DEFAULTS.fetch(key), other => 23))
    end
    [nil, -100, -1, 0, 1, 40, 100, 101, 1_000, -1.8, 39.8, 100.8,
      '', '70', ' 42 ', '12.9', 'garbage', '99tail'].each do |raw|
      expected = [[raw.to_i, 0].max, 100].min
      check.call({key => raw}, GameRoomAudio::DEFAULTS.merge(key => expected))
    end
  end

  [nil, false, true, [], [40], '40', 40].each do |raw|
    check.call(raw, GameRoomAudio::DEFAULTS)
  end
  [nil, false, true, 1, 'true', [], {}].each do |raw|
    check.call({'music' => raw, 'effects' => raw},
      GameRoomAudio::DEFAULTS.merge('music' => raw == true, 'effects' => raw == true))
  end
  check.call({}, GameRoomAudio::DEFAULTS)
  check.call({'effects' => false}, GameRoomAudio::DEFAULTS.merge('effects' => false))

  audio = check.call({'music_volume' => 61, 'effects_volume' => 22},
    GameRoomAudio::DEFAULTS.merge('music_volume' => 61, 'effects_volume' => 22))
  requested = {'music' => true, 'effects' => true, 'music_volume' => [], 'effects_volume' => '82'}
  snapshot = Marshal.dump(requested)
  before = writes
  audio.save(requested)
  expected = GameRoomAudio::DEFAULTS.merge('music' => true, 'effects' => true, 'effects_volume' => 82)
  assert(audio.settings == expected && runtime.read_json(name) == expected && writes == before + 1,
    'explicit save did not write one normalized preference record')
  assert(Marshal.dump(requested) == snapshot, 'normalization mutated caller preferences')

  refuse_write = true
  bytes = File.binread(runtime.data_path(name))
  begin
    audio.save('music' => false, 'music_volume' => 10)
    raise 'failed preference write was reported as success'
  rescue RuntimeError => error
    assert(error.message == 'Cannot save audio settings', 'wrong save failure')
  end
  assert(audio.settings == expected && File.binread(runtime.data_path(name)) == bytes,
    'failed save replaced working preferences or saved bytes')
  audio.close
  puts "Krowa audio preferences: #{cases} native JSON constructor cases, explicit save and failed save OK"
end
