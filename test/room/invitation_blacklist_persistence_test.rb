require 'json'
require 'tmpdir'
require_relative '../support/host_source'
require_relative '../support/ui'
require EltenTestHost.file('src/eapi/resources.rb')
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../support/settings_widget'

class BlacklistPersistenceApp < EltenGameRoom
  class << self; attr_accessor :fixture_runtime, :reads, :forbid_reads; end
  def self.read_json(path, default:)
    raise 'notification reopened settings' if forbid_reads
    self.reads = reads.to_i + 1
    fixture_runtime.read_json(path, default: default)
  end
  def read_json(*args, **options); self.class.read_json(*args, **options); end
  def update_json(*args, **options, &block); self.class.fixture_runtime.update_json(*args, **options, &block); end
end

GameRoomLocalization.boot(settings: {}, host_language: 'en')
checks = 0
Dir.mktmpdir('invitation-blacklist-') do |directory|
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
  runtime.define_singleton_method(:write_json) { |*args| writes += 1; super(*args) }
  BlacklistPersistenceApp.fixture_runtime = runtime
  app = BlacklistPersistenceApp.new
  [nil, false, true, 4, 'Bob', {}, [], [' Bob ', 'bOB', '', '  ', nil, 7, {}, ['Eve'], 'Carol']].each do |raw|
    stored = {'invitation_blacklist' => raw, 'sentinel' => 42, 'sound_volumes' => {'all' => 63}}
    runtime.write_json('settings.json', stored)
    bytes = File.binread(runtime.data_path('settings.json'))
    before = writes
    expected = raw.is_a?(Array) && !raw.empty? ? %w[Bob Carol] : []
    settings = app.send(:game_room_settings, reload: true)
    assert(settings['invitation_blacklist'] == expected, "wrong normalization #{raw.inspect}")
    assert(settings['sentinel'] == 42 && settings['sound_volumes']['all'] == 63, 'unrelated settings changed')
    assert(File.binread(runtime.data_path('settings.json')) == bytes && writes == before, 'read automatically rewrote file')
    checks += 1
  end
  app.send(:update_game_room_settings) { |state| state['invitation_blacklist'] = [' Bob ', 'bob'] }
  assert(app.send(:game_room_settings, reload: true)['invitation_blacklist'] == ['Bob'], 'native saved setting did not reload')
  BlacklistPersistenceApp.forbid_reads = true
  before = BlacklistPersistenceApp.reads
  100.times do
    assert(!BlacklistPersistenceApp.invitation_sender_allowed?('bOb'), 'cached filter ignored case')
    assert(BlacklistPersistenceApp.invitation_sender_allowed?('Carol'), 'cached filter hid other user')
  end
  assert(BlacklistPersistenceApp.reads == before, 'filter reopened settings')
  original_update = runtime.method(:update_json)
  runtime.define_singleton_method(:update_json) do |path, **options, &edit|
    state = read_json(path, **options)
    edit.call(state)
    raise IOError, 'controlled save refusal'
  end
  begin
    app.send(:update_game_room_settings) { |state| state['invitation_blacklist'] = [] }
    raise 'save failure not propagated'
  rescue IOError
  end
  assert(!BlacklistPersistenceApp.invitation_sender_allowed?('Bob'), 'failed save published the staged removal')
  runtime.define_singleton_method(:update_json, original_update)
  app.send(:update_game_room_settings) { |state| state['invitation_blacklist'] = [] }
  assert(BlacklistPersistenceApp.invitation_sender_allowed?('Bob'), 'committed removal was not immediate')
  assert(runtime.read_json('settings.json')['invitation_blacklist'] == [], 'explicit empty list was not persisted')
end
puts "PASS blacklist: #{checks} native JSON read cases, no automatic writes, committed cache, failed Save and explicit removal"
