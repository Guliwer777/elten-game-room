require 'tmpdir'
require 'json'
require 'digest'
if ARGV.first
  require_relative '../support/binary_rules_load'
else
  require_relative '../../lib/tournaments/drafts'
end
require_relative '../support/assertions'
include GameRoomTest::Assertions

Dir.mktmpdir('draft-v2-', ENV.fetch('TMPDIR')) do |directory|
  program = Object.new
  program.define_singleton_method(:data_path) { directory }
  store = GameRoomTournaments::Drafts.new(program, owner: 'Tester')
  path = File.join(directory, "tournament-drafts-#{Digest::SHA256.hexdigest('tester')}.json")
  legacy = {'format' => 'round_robin', 'rematch' => true, 'participants' => [],
    'windows' => [{'date' => '2026-10-05', 'start' => '00:00', 'end_date' => '2026-10-05', 'end' => '12:00'}],
    'players_per_match' => 2, 'pairing' => 'all_combinations', 'name' => 'Szkic — Żółć',
    'game_id' => 'ninety_nine', 'game_options' => {'starting_tokens' => 9, 'omniscient_bots' => false, 'thinking_time' => 0, 'bot_delay' => 0},
    'id' => '96412592-c955-4d5b-afc0-39b5693b7eeb', 'owner' => 'tester', 'revision' => 1,
    'created_at' => 1790934528, 'updated_at' => 1790934528, 'status' => 'draft'}
  [legacy, legacy.merge('group_count' => 2, 'places_per_group' => 1)].each do |record|
    bytes = JSON.generate('schema_version' => 2, 'owner' => 'tester', 'drafts' => [record]).b
    File.binwrite(path, bytes)
    rows = store.list
    assert_equal(1, rows.size)
    assert_equal(record, rows.first.reject { |key, _| !record.key?(key) })
    assert_equal(nil, rows.first['group_advancement'])
    assert_equal(bytes, File.binread(path), 'Reading old drafts must not rewrite them')
    backup = "#{path}.v2-#{Digest::SHA256.hexdigest(bytes)}.bak"
    File.binwrite(backup, 'different backup')
    assert_raises(IOError) { store.update(record['id'], {'name' => 'Poprawiony szkic'}, expected_revision: 1) }
    assert_equal(bytes, File.binread(path))
    assert_equal('different backup', File.binread(backup))
    File.binwrite(backup, bytes)
    changed = store.update(record['id'], {'name' => 'Poprawiony szkic'}, expected_revision: 1)
    assert_equal(2, changed['revision'])
    assert_equal(record['windows'], changed['windows'])
    assert_equal(bytes, File.binread(backup))
    assert_equal(changed, GameRoomTournaments::Drafts.new(program, owner: 'tester').list.first)
    assert_equal(GameRoomTournaments::Drafts::RECORD_FIELDS.sort, changed.keys.sort)
  end
  [legacy.merge('unknown' => true), legacy.reject { |key, _| key == 'windows' },
    legacy.merge('group_count' => 2), legacy.merge('group_count' => 0, 'places_per_group' => 1)].each do |record|
    bytes = JSON.generate('schema_version' => 2, 'owner' => 'tester', 'drafts' => [record]).b
    File.binwrite(path, bytes)
    assert_raises(GameRoomTournaments::Drafts::Corrupt) { store.list }
    assert_equal(bytes, File.binread(path))
  end
end
puts 'PASS historical v2 drafts: read without writes, exact backup before update, stable fields and corruption guards'
