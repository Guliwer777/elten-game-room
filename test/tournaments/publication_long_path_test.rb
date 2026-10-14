require 'tmpdir'
require 'fileutils'
require 'date'
if ARGV.first
  require_relative '../support/binary_rules_load'
else
  require_relative '../../games/catalog'
  require_relative '../../lib/tournaments/local_test_tables'
  require_relative '../../lib/tournaments/public_service'
end
require_relative '../support/assertions'
include GameRoomTest::Assertions

Dir.mktmpdir('long-publication-', ENV.fetch('TMPDIR')) do |root|
  padding = 160 - root.bytesize - 1
  raise 'Test root is too long for the intended boundary' unless padding > 0
  directory = File.join(root, 'x' * padding)
  actor = -> { 'LocalProbe' }
  now = Time.now.to_i
  tables = GameRoomTournaments::LocalTestTables.new(directory: File.join(root, 'tables'), user: actor, clock: -> { now })
  journal = GameRoomTournaments::OperationJournal.new(directory: directory, owner: actor.call, backend_identity: tables.backend_identity)
  assert(journal.path.bytesize < 256 && (journal.path + '.tmp-' + 'a' * 24).bytesize >= 260, 'Must reproduce the real Windows temporary-path boundary')
  sentinel = File.join(directory, '.journal-unrelated.tmp')
  File.binwrite(sentinel, 'unrelated')
  gateway = GameRoomTournaments::TablesGateway.new(server_tables: tables, user: actor, operation_error_classes: [GameRoomTournaments::LocalTestTables::Error])
  registry = GameRoomGames::CATALOG
  service = GameRoomTournaments::PublicService.new(gateway: gateway, journal: journal, registry: registry,
    user: actor, backend_identity: tables.backend_identity, clock: -> { now })
  day = (Date.today + 1).strftime('%Y-%m-%d')
  draft = {'name' => 'Local long-path test', 'game_id' => 'tic_tac_toe', 'game_options' => registry.build('tic_tac_toe').default_options,
    'format' => 'round_robin', 'rematch' => false, 'participants' => [], 'windows' => [{'date' => day, 'start' => '12:00', 'end_date' => day, 'end' => '13:00'}],
    'players_per_match' => 2, 'pairing' => 'all_combinations', 'group_count' => nil, 'places_per_group' => nil, 'group_advancement' => nil}
  input = {draft: draft, intent_id: 'long-path-publication', rules: 'Local test only', registration_opens_at: now,
    registration_closes_at: now + 60, timezone: 'local_test:system'}
  result = service.publish(**input)
  assert_equal('confirmed', result['status'])
  repeated = service.publish(**input)
  assert_equal(result['id'], repeated['id'])
  assert_equal('confirmed', repeated['status'])
  assert_equal(result['values'], repeated['values'])
  bytes = File.binread(journal.path)
  reopened = GameRoomTournaments::OperationJournal.new(directory: directory, owner: actor.call, backend_identity: tables.backend_identity)
  assert_equal([repeated], reopened.list)
  assert_equal(bytes, File.binread(journal.path))
  assert_equal(1, tables.fetch('tournament_announcements').select.size)
  assert_equal('unrelated', File.binread(sentinel))
  assert_equal([sentinel], Dir.glob(File.join(directory, '.journal-*.tmp')))
end
puts 'PASS long-path publication: confirmed, single insert, durable cold journal, atomic temporary cleanup and unrelated file retained'
