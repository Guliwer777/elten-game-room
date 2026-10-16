# encoding: UTF-8
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'
require_relative '../support/tournament_operation_journal'

source = File.expand_path('../../lib/tournaments/operation_journal.rb', __dir__)
require source if File.file?(source)

class TournamentOperationJournalTest
  def assert(value, message = 'Niespełniona asercja')
    @assertions += 1
    raise message unless value
  end

  def equal(expected, actual)
    assert(expected.eql?(actual), "Oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def journal(directory: @directory, owner: 'Żaneta', backend_identity: 'local_test:D:/test/baza.json')
    assert(defined?(GameRoomTournaments::OperationJournal), 'Brak trwałego OperationJournal')
    GameRoomTournaments::OperationJournal.new(directory: directory, owner: owner, backend_identity: backend_identity)
  end

  def publication(key = 'pub-first')
    {'publication_key' => key, 'schema_version' => 1, 'title' => 'Zażółć gęślą',
      'game' => 'unknown_game', 'rules' => "Reguły\nDruga linia", 'settings_json' => '{"opcja":[true,null,"ż"]}',
      'schedule_json' => '{"windows":[]}', 'registration_opens_at' => 100,
      'registration_closes_at' => 200, 'timezone' => 'Europe/Warsaw'}
  end

  def join_values(key = 'join-first')
    {'tournament_id' => 17, 'operation_key' => key, 'kind' => 'join'}
  end

  def frozen_tree(value)
    assert(value.frozen?, "Mutowalny wynik: #{value.inspect}")
    value.each { |key, child| frozen_tree(key); frozen_tree(child) } if value.is_a?(Hash)
    value.each { |child| frozen_tree(child) } if value.is_a?(Array)
  end

  def test_prepare_restart_unicode_and_frozen_payload
    store = journal
    equal('żaneta', store.owner)
    equal('local_test:D:/test/baza.json', store.backend_identity)
    digest = Digest::SHA256.hexdigest(JSON.generate([store.owner, store.backend_identity]))
    equal(File.join(@directory, "tournament-operations-#{digest}.json"), store.path)
    equal([], store.list)
    equal(nil, store.fetch('missing'))
    equal(nil, store.find(kind: 'publication', intent_id: 'draft:1'))
    assert(!File.exist?(store.path), 'Odczyt nie tworzy JSON')
    values = publication
    before = Marshal.dump(values)
    record = store.prepare(kind: 'publication', intent_id: 'szkic-Ż:1', values: values)
    equal(before, Marshal.dump(values))
    assert(!values.frozen? && !values['title'].frozen?, 'Nie wolno zamrażać argumentów')
    equal(values, record['values'])
    equal('prepared', record['status'])
    equal(1, record['revision'])
    equal(nil, record['evidence'])
    equal('tournament_announcements', record['table_name'])
    equal(%w[evidence id intent_id kind revision status table_name values], record.keys.sort)
    assert(record['id'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/))
    frozen_tree(record)
    values['title'].replace('zmiana argumentu')
    reopened = journal
    equal(record, reopened.fetch(record['id']))
    equal(record, reopened.find(kind: 'publication', intent_id: 'szkic-Ż:1'))
    frozen_tree(reopened.list)
    assert(!reopened.fetch(record['id']).equal?(record))
    bytes = File.binread(store.path)
    document = JSON.parse(bytes)
    equal(%w[backend_identity operations owner schema_version], document.keys.sort)
    equal(1, document['schema_version'])
    equal([record], document['operations'])
    equal([record], store.list)
    equal(bytes, File.binread(store.path))
  end

  def error(kind, code = nil)
    @assertions += 1
    begin
      yield
    rescue kind => failure
      equal(code, failure.code) if code
      return failure
    end
    raise "Oczekiwano błędu #{kind}: #{code}"
  end

  def test_prepare_deduplicates_intent_retaining_first_key_and_rejects_changed_content
    first = journal
    second = journal
    values = publication('original-key')
    record = first.prepare(kind: 'publication', intent_id: 'draft:revision:1', values: values)
    bytes = File.binread(first.path)
    duplicate = second.prepare(kind: 'publication', intent_id: 'draft:revision:1', values: publication('different-key'))
    equal(record, duplicate)
    equal(bytes, File.binread(first.path))
    equal('original-key', duplicate['values']['publication_key'])
    changed = publication('different-key').merge('title' => 'Inna treść')
    error(GameRoomTournaments::OperationJournal::Conflict, :intent_conflict) do
      second.prepare(kind: 'publication', intent_id: 'draft:revision:1', values: changed)
    end
    equal(bytes, File.binread(first.path))
    joined = first.prepare(kind: 'join', intent_id: 'draft:revision:1', values: join_values('original-join'))
    equal('tournament_registrations', joined['table_name'])
    equal(joined, second.prepare(kind: 'join', intent_id: 'draft:revision:1', values: join_values('other-join')))
    error(GameRoomTournaments::OperationJournal::Conflict, :intent_conflict) do
      second.prepare(kind: 'join', intent_id: 'draft:revision:1', values: join_values.merge('tournament_id' => 18))
    end
    equal(2, first.list.length)
  end

  include TournamentOperationJournalProcesses

  def test_claim_is_durable_single_winner_across_real_processes
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'claim', values: join_values)
    workers([['claim', record['id']], ['claim', record['id']]]) do |children|
      results = release_workers(children)
      equal(1, results.count(nil))
      winner = results.compact.fetch(0)
      equal('attempted', winner['status'])
      equal(2, winner['revision'])
      equal(record['values'], winner['values'])
      equal(winner, journal.fetch(record['id']))
    end
    bytes = File.binread(store.path)
    equal(nil, journal.claim(record['id']))
    equal(nil, store.claim('missing'))
    equal(bytes, File.binread(store.path))
  end

  def test_prepare_race_preserves_first_key_in_two_real_processes
    workers([['prepare', 'first-key'], ['prepare', 'second-key']]) do |children|
      results = release_workers(children)
      equal(results[0], results[1])
      assert(%w[first-key second-key].include?(results[0]['values']['operation_key']))
      equal(results, [journal.list.fetch(0)] * 2)
      equal(1, journal.list.length)
    end
  end

  def test_resolve_revision_evidence_and_latched_terminal_states
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'resolve', values: join_values)
    first = store.resolve(record['id'], status: 'confirmed', evidence: {'rows' => [17]}, expected_revision: 1)
    equal(2, first['revision'])
    equal('confirmed', first['status'])
    frozen_tree(first)
    bytes = File.binread(store.path)
    error(GameRoomTournaments::OperationJournal::Conflict, :revision_conflict) do
      store.resolve(record['id'], status: 'confirmed', evidence: {}, expected_revision: 1)
    end
    error(GameRoomTournaments::OperationJournal::Conflict, :terminal_conflict) do
      store.resolve(record['id'], status: 'outside_window', evidence: {}, expected_revision: 2)
    end
    equal(nil, store.claim(record['id']))
    equal(bytes, File.binread(store.path))
    evidence = {'rows' => [17, 18]}
    second = store.resolve(record['id'], status: 'confirmed', evidence: evidence, expected_revision: 2)
    evidence['rows'] << 19
    equal({'rows' => [17, 18]}, second['evidence'])
    equal(3, second['revision'])
    conflict = store.resolve(record['id'], status: 'conflict', evidence: {'reason' => 'duplicate'}, expected_revision: 3)
    equal(4, conflict['revision'])
    %w[confirmed outside_window].each do |status|
      error(GameRoomTournaments::OperationJournal::Conflict, :terminal_conflict) do
        journal.resolve(record['id'], status: status, evidence: {}, expected_revision: 4)
      end
    end
    equal(5, store.resolve(record['id'], status: 'conflict', evidence: {}, expected_revision: 4)['revision'])
    attempted = store.prepare(kind: 'join', intent_id: 'attempted-resolve', values: join_values)
    store.claim(attempted['id'])
    equal('outside_window', store.resolve(attempted['id'], status: 'outside_window', evidence: {'rows' => []}, expected_revision: 2)['status'])
    error(GameRoomTournaments::OperationJournal::Conflict, :missing_operation) do
      store.resolve('missing', status: 'confirmed', evidence: {}, expected_revision: 1)
    end
    %w[prepared attempted unknown].each do |status|
      error(GameRoomTournaments::OperationJournal::Invalid, :invalid_status) do
        store.resolve(record['id'], status: status, evidence: {}, expected_revision: 5)
      end
    end
    [nil, 0, -1, 1.0, '5', 2**63].each do |revision|
      error(GameRoomTournaments::OperationJournal::Invalid, :invalid_revision) do
        store.resolve(record['id'], status: 'conflict', evidence: {}, expected_revision: revision)
      end
    end
  end

  def test_resolve_rejects_non_hash_evidence_without_writing
    store = journal
    %w[prepared attempted].each do |from|
      %w[confirmed outside_window conflict].each do |status|
        record = store.prepare(kind: 'join', intent_id: "shape-#{from}-#{status}", values: join_values)
        record = store.claim(record['id']) if from == 'attempted'
        equal(nil, record['evidence'])
        bytes = File.binread(store.path)
        [nil, [], [1, nil], '', 'tekst', true, false, 1, 1.25].each do |evidence|
          error(GameRoomTournaments::OperationJournal::Invalid, :invalid_evidence) do
            store.resolve(record['id'], status: status, evidence: evidence, expected_revision: record['revision'])
          end
          equal(bytes, File.binread(store.path))
          equal(record, journal.fetch(record['id']))
        end
      end
    end
  end

  def test_restart_rejects_non_hash_terminal_evidence_without_repair
    store = journal
    healthy = store.prepare(kind: 'join', intent_id: 'healthy', values: join_values)
    damaged = store.prepare(kind: 'join', intent_id: 'damaged', values: join_values)
    good = JSON.parse(File.binread(store.path))
    # Revisions 2 and 3 cover terminal records resolved from prepared and attempted.
    [2, 3].each do |revision|
      %w[confirmed outside_window conflict].each do |status|
        [nil, [], [1, nil], '', 'tekst', true, false, 1, 1.25].each do |evidence|
          document = Marshal.load(Marshal.dump(good))
          document['operations'][1].merge!('status' => status, 'revision' => revision, 'evidence' => evidence)
          bytes = JSON.generate(document).b
          File.binwrite(store.path, bytes)
          reopened = journal
          operations = [
            proc { reopened.list },
            proc { reopened.fetch(healthy['id']) },
            proc { reopened.fetch(damaged['id']) },
            proc { reopened.find(kind: 'join', intent_id: 'healthy') },
            proc { reopened.prepare(kind: 'join', intent_id: 'new', values: join_values) },
            proc { reopened.claim(healthy['id']) },
            proc { reopened.resolve(healthy['id'], status: 'conflict', evidence: {}, expected_revision: 1) }
          ]
          operations.each do |operation|
            error(GameRoomTournaments::OperationJournal::Corrupt, :corrupt_journal, &operation)
            equal(bytes, File.binread(store.path))
          end
        end
      end
    end
  end

  def test_hash_evidence_roundtrips_all_terminal_states_and_nonterminal_nil
    store = journal
    %w[prepared attempted].each do |from|
      %w[confirmed outside_window conflict].each do |status|
        record = store.prepare(kind: 'join', intent_id: "roundtrip-#{from}-#{status}", values: join_values)
        record = store.claim(record['id']) if from == 'attempted'
        equal(from, record['status'])
        equal(nil, record['evidence'])
        equal(record, journal.fetch(record['id']))
        [{}, {'nested' => [{'values' => [true, false, nil, 1, 1.25, 'ż']}]}].each do |evidence|
          before = Marshal.dump(evidence)
          deep_freeze_input(evidence)
          resolved = store.resolve(record['id'], status: status, evidence: evidence, expected_revision: record['revision'])
          equal(status, resolved['status'])
          equal(record['revision'] + 1, resolved['revision'])
          equal(evidence, resolved['evidence'])
          equal(before, Marshal.dump(evidence))
          frozen_tree(resolved['evidence'])
          persisted = journal.fetch(record['id'])
          equal(resolved, persisted)
          frozen_tree(persisted['evidence'])
          record = resolved
        end
      end
    end
  end

  def test_scope_validation_and_no_local_to_server_migration
    invalid = GameRoomTournaments::OperationJournal::Invalid
    [nil, 12, '', ' x', 'x ', "x\n", 'x' * 65, "\u0085", "\u00a0x", "x\u00a0", "\xff".b].each do |owner|
      error(invalid, :invalid_owner) { journal(owner: owner) }
    end
    [nil, 12, '', "x\n", 'b' * 4097, "\xff".b].each do |backend|
      error(invalid, :invalid_backend_identity) { journal(backend_identity: backend) }
    end
    owner = 'Ż' * 64
    backend = ' SERVER:Opaque/../Case Sensitive '
    store = journal(owner: owner.freeze, backend_identity: backend.freeze)
    equal(owner.downcase, store.owner)
    equal(backend, store.backend_identity)
    record = store.prepare(kind: 'join', intent_id: 'scope', values: join_values)
    equal(record, journal(owner: owner.downcase, backend_identity: backend).fetch(record['id']))
    [journal(owner: 'Other', backend_identity: backend),
      journal(owner: owner, backend_identity: backend.downcase),
      journal(owner: owner, backend_identity: 'local_test:/same'),
      journal(owner: owner, backend_identity: 'server:/same')].each do |other|
      equal([], other.list)
      assert(!File.exist?(other.path))
      assert(other.path != store.path)
    end
    equal([record], store.list)
  end

  def test_payload_validation_exact_fields_and_unicode_frozen_values
    store = journal
    invalid = GameRoomTournaments::OperationJournal::Invalid
    [nil, '', 'x' * 257, "x\n", "\xff".b].each do |intent|
      error(invalid, :invalid_intent) { store.prepare(kind: 'join', intent_id: intent, values: join_values) }
    end
    [nil, :join, 'other'].each do |kind|
      error(invalid, :invalid_kind) { store.prepare(kind: kind, intent_id: 'x', values: join_values) }
    end
    bad = [nil, [], join_values.merge(:other => 1), join_values.merge('extra' => 1),
      join_values.reject { |key, _| key == 'operation_key' }, join_values.merge('kind' => 'leave')]
    [0, -1, 1.0, true, '1', 2**63].each { |id| bad << join_values.merge('tournament_id' => id) }
    ['', 'a' * 65, 'ą', 'with space', "bad\n", '__bad!'].each do |key|
      bad << join_values(key)
    end
    bad.each { |values| error(invalid) { store.prepare(kind: 'join', intent_id: 'x', values: values) } }
    publication.each_key do |key|
      error(invalid) { store.prepare(kind: 'publication', intent_id: 'x', values: publication.reject { |field, _| field == key }) }
    end
    [publication.merge('extra' => 1), publication.merge('title' => []), publication.merge('schema_version' => 3),
      publication.merge('settings_json' => '{"x":1,"x":2}'), publication.merge('settings_json' => '{"nest":{"__user":1}}'),
      publication.merge('schedule_json' => 'not JSON'), publication.merge('registration_closes_at' => 1.5)].each do |values|
      error(invalid) { store.prepare(kind: 'publication', intent_id: 'x', values: values) }
    end
    assert(!File.exist?(store.path))
    values = publication('A_9-z').merge('rules' => 'Ż😀' * 8192)
    deep_freeze_input(values)
    result = store.prepare(kind: 'publication', intent_id: ('ż' * 128).freeze, values: values)
    equal(values, result['values'])
    frozen_tree(result)
    equal(result, journal.list.fetch(0))
    max_join = store.prepare(kind: 'join', intent_id: 'max', values: join_values.merge('tournament_id' => (2**63) - 1))
    equal((2**63) - 1, max_join['values']['tournament_id'])
  end

  def deep_freeze_input(value)
    value.each { |key, child| deep_freeze_input(key); deep_freeze_input(child) } if value.is_a?(Hash)
    value.each { |child| deep_freeze_input(child) } if value.is_a?(Array)
    value.freeze
  end

  def test_evidence_and_payload_json_budgets_cycles_types_and_boundaries
    store = journal
    invalid = GameRoomTournaments::OperationJournal::Invalid
    too_large = publication.merge('rules' => 'x' * 160_000)
    error(invalid, :payload_too_large) { store.prepare(kind: 'publication', intent_id: 'large', values: too_large) }
    cycle = []; cycle << cycle
    deep = 0; 12.times { deep = [deep] }
    bad = [{:symbol => 1}, {'nest' => [{'__id' => 1}]}, {'value' => Float::INFINITY}, {'value' => Float::NAN},
      {'value' => 2**63}, {'value' => -(2**63) - 1}, {'value' => Object.new}, {'value' => "\xff".b},
      {'value' => cycle}, {'value' => deep}, {'' => [0] * 8190}]
    record = store.prepare(kind: 'join', intent_id: 'evidence', values: join_values)
    bytes = File.binread(store.path)
    bad.each do |value|
      error(invalid, :invalid_values) { store.resolve(record['id'], status: 'confirmed', evidence: value, expected_revision: 1) }
      equal(bytes, File.binread(store.path))
    end
    text = 'x' * (16_384 - JSON.generate({'text' => ''}).bytesize)
    error(invalid, :evidence_too_large) do
      store.resolve(record['id'], status: 'confirmed', evidence: {'text' => text + 'x'}, expected_revision: 1)
    end
    # The root Hash, key and JSON quotes all count toward the same byte budget.
    result = store.resolve(record['id'], status: 'confirmed', evidence: {'text' => text.freeze}.freeze, expected_revision: 1)
    equal(text.bytesize, result['evidence']['text'].bytesize)
    equal(16_384, JSON.generate(result['evidence']).bytesize)
    shared = [true, false, nil, -(2**63), (2**63) - 1, 1.25, 'ż']
    result = store.resolve(record['id'], status: 'confirmed', evidence: {'a' => shared, 'b' => shared}.freeze, expected_revision: 2)
    equal(shared, result['evidence']['a'])
    frozen_tree(result)
    deep = 0; 11.times { deep = [deep] }
    evidence = {'value' => deep}
    equal(evidence, store.resolve(record['id'], status: 'confirmed', evidence: evidence, expected_revision: 3)['evidence'])
    # Hash + key + Array + 8189 scalars = 8192 nodes, also exactly 16384 bytes.
    nodes = {'' => [0] * 8189}
    equal(16_384, JSON.generate(nodes).bytesize)
    equal(nodes, store.resolve(record['id'], status: 'confirmed', evidence: nodes, expected_revision: 4)['evidence'])
    base = publication.merge('rules' => '')
    base['rules'] = 'x' * (160_000 - JSON.generate(base).bytesize)
    equal(160_000, JSON.generate(base).bytesize)
    accepted = store.prepare(kind: 'publication', intent_id: 'boundary', values: base)
    equal(base, accepted['values'])
    error(invalid, :payload_too_large) do
      store.prepare(kind: 'publication', intent_id: 'boundary-plus', values: base.merge('rules' => base['rules'] + 'x'))
    end
    ['{"x":9223372036854775808}', '{"x":1e999}', JSON.generate({'x' => [0] * 8192})].each do |json|
      error(invalid) { store.prepare(kind: 'publication', intent_id: 'embedded', values: publication.merge('settings_json' => json)) }
    end
  end

  def test_entire_document_corruption_is_never_replaced
    store = journal
    first = store.prepare(kind: 'join', intent_id: 'first', values: join_values)
    store.prepare(kind: 'publication', intent_id: 'second', values: publication)
    good = JSON.parse(File.binread(store.path))
    mutations = [
      proc { |d| d['schema_version'] = 2 }, proc { |d| d['schema_version'] = 1.0 },
      proc { |d| d['owner'] = 'other' }, proc { |d| d['backend_identity'] = 'server:other' },
      proc { |d| d['extra'] = 1 }, proc { |d| d['operations'] = {} },
      proc { |d| d['operations'][1]['id'] = d['operations'][0]['id'] },
      proc { |d| d['operations'] << d['operations'][0].merge('id' => SecureRandom.uuid) }
    ]
    {'id' => 'not-uuid', 'revision' => 0, 'status' => 'retry', 'kind' => 'leave',
      'intent_id' => '', 'table_name' => 'other', 'values' => {'kind' => 'join'}, 'evidence' => {}}.each do |key, value|
      mutations << proc { |d| d['operations'][1][key] = value }
    end
    mutations.concat([
      proc { |d| d['operations'][1]['revision'] = 2 },
      proc { |d| d['operations'][1]['status'] = 'attempted' },
      proc { |d| d['operations'][1]['status'] = 'confirmed' },
      proc { |d| d['operations'][1]['extra'] = 1 },
      proc { |d| d['operations'][1].delete('evidence') },
      proc { |d| d['operations'][1]['values']['settings_json'] = '{"x":0,"x":1}' }
    ])
    mutations.each do |mutation|
      document = Marshal.load(Marshal.dump(good)); mutation.call(document)
      bytes = JSON.generate(document).b
      File.binwrite(store.path, bytes)
      error(GameRoomTournaments::OperationJournal::Corrupt) { store.fetch(first['id']) }
      error(GameRoomTournaments::OperationJournal::Corrupt) { journal.prepare(kind: 'join', intent_id: 'new', values: join_values) }
      equal(bytes, File.binread(store.path))
    end
    ['{', '', '[]', 'null', "{\"owner\":\"\xff\"}".b,
      JSON.generate(good).sub('"schema_version":1', '"schema_version":1,"schema_version":1'),
      JSON.generate(good).sub('"tournament_id":17', '"tournament_id":17,"tournament_id":17'),
      JSON.generate(good).sub('"tournament_id":17', '"tournament_id":17,"tournament_\\u0069d":17')].each do |bytes|
      File.binwrite(store.path, bytes)
      error(GameRoomTournaments::OperationJournal::Corrupt) { store.list }
      equal(bytes.b, File.binread(store.path))
    end
  end

  def test_parser_capability_probe_fails_closed_when_option_ignored
    original = JSON.method(:parse)
    JSON.define_singleton_method(:parse) do |source, **options|
      options.delete(:allow_duplicate_key)
      original.call(source, **options.merge(allow_duplicate_key: true))
    end
    error(GameRoomTournaments::OperationJournal::Error, :incompatible_runtime) { journal }
    equal([], Dir.glob(File.join(@directory, '*')))
  ensure
    JSON.define_singleton_method(:parse, original) if original
  end

  def test_operation_file_limits_and_revision_overflow_preserve_bytes
    store = journal
    template = store.prepare(kind: 'join', intent_id: 'template', values: join_values)
    document = JSON.parse(File.binread(store.path))
    document['operations'] = Array.new(4096) { |i| template.merge('id' => SecureRandom.uuid, 'intent_id' => "intent-#{i}") }
    File.binwrite(store.path, JSON.generate(document))
    equal(4096, store.list.size)
    bytes = File.binread(store.path)
    existing = store.prepare(kind: 'join', intent_id: 'intent-0', values: join_values('changed-key'))
    equal(document['operations'][0], existing)
    error(GameRoomTournaments::OperationJournal::Invalid, :operation_limit) do
      store.prepare(kind: 'join', intent_id: 'overflow', values: join_values)
    end
    equal(bytes, File.binread(store.path))
    document['operations'] << template
    File.binwrite(store.path, JSON.generate(document))
    error(GameRoomTournaments::OperationJournal::Corrupt) { store.list }
    document['operations'] = [template.merge('status' => 'confirmed', 'revision' => (2**63) - 1, 'evidence' => {})]
    File.binwrite(store.path, JSON.generate(document))
    bytes = File.binread(store.path)
    error(GameRoomTournaments::OperationJournal::Invalid, :revision_limit) do
      store.resolve(template['id'], status: 'confirmed', evidence: {}, expected_revision: (2**63) - 1)
    end
    equal(bytes, File.binread(store.path))
    valid = JSON.generate(document)
    File.binwrite(store.path, valid + (' ' * (8_388_608 - valid.bytesize)))
    equal(1, store.list.size)
    File.open(store.path, 'ab') { |file| file.write(' ') }
    bytes = File.binread(store.path)
    error(GameRoomTournaments::OperationJournal::Corrupt, :file_limit) { store.list }
    error(GameRoomTournaments::OperationJournal::Corrupt, :file_limit) { store.claim(template['id']) }
    equal(bytes, File.binread(store.path))
    # Enough valid payloads to cross 8 MiB on one more prepare.
    values = publication.merge('rules' => 'x' * 159_000)
    record = template.merge('kind' => 'publication', 'values' => values, 'table_name' => 'tournament_announcements')
    document['operations'] = Array.new(52) { |i| record.merge('id' => SecureRandom.uuid, 'intent_id' => "large-#{i}") }
    File.binwrite(store.path, JSON.generate(document))
    assert(File.size(store.path) < 8_388_608)
    bytes = File.binread(store.path)
    error(GameRoomTournaments::OperationJournal::Invalid, :file_limit) do
      store.prepare(kind: 'publication', intent_id: 'file-overflow', values: values)
    end
    equal(bytes, File.binread(store.path))
  end

  def test_directory_validation_and_existing_links_are_rejected
    invalid = GameRoomTournaments::OperationJournal::Invalid
    [nil, '', ' ', "bad\n", 'x' * 4097, 'C:relative', '//server/share', '//?/C:/device'].each do |path|
      error(invalid, :invalid_directory) { journal(directory: path) }
    end
    file = File.join(@directory, 'ordinary-file'); File.binwrite(file, 'original')
    error(invalid, :invalid_directory) { journal(directory: file) }
    original = journal
    # Hard links need no elevated Windows symlink privilege.
    [:json, :lock].each do |target|
      path = target == :json ? original.path : original.path + '.lock'
      File.link(file, path)
      begin
        error(GameRoomTournaments::OperationJournal::Error, :unsafe_path) { original.list }
        equal('original', File.binread(file))
      ensure
        File.unlink(path)
      end
    end
    FileUtils.mkdir_p(original.path)
    error(GameRoomTournaments::OperationJournal::Error, :unsafe_path) { original.list }
    FileUtils.rmdir(original.path)
    # Check symlink guards deterministically even on Windows without symlink privilege.
    real_lstat = File.method(:lstat)
    fake = Object.new
    fake.define_singleton_method(:symlink?) { true }
    File.define_singleton_method(:lstat) do |path|
      path == GameRoomTournaments::LocalFilesystem.native(@journal_unsafe_test_path) ? fake : real_lstat.call(path)
    end
    File.instance_variable_set(:@journal_unsafe_test_path, @directory)
    error(GameRoomTournaments::OperationJournal::Error, :unsafe_path) { journal }
    File.instance_variable_set(:@journal_unsafe_test_path, original.path)
    error(GameRoomTournaments::OperationJournal::Error, :unsafe_path) { original.list }
  ensure
    File.define_singleton_method(:lstat, real_lstat) if real_lstat
    File.remove_instance_variable(:@journal_unsafe_test_path) if File.instance_variable_defined?(:@journal_unsafe_test_path)
  end

  def test_relative_directory_is_resolved_once_across_cwd_changes
    original = Dir.pwd
    Dir.chdir(@directory)
    store = journal(directory: './nested/portable')
    expected = File.join(@directory, 'nested/portable')
    Dir.chdir(original)
    assert(store.path.start_with?(expected))
    record = store.prepare(kind: 'join', intent_id: 'cwd', values: join_values)
    equal(record, journal(directory: expected).fetch(record['id']))
  ensure
    Dir.chdir(original) if original
  end

  def with_file_fault(method, replacement)
    original = File.method(method)
    File.define_singleton_method(method, &replacement.call(original))
    yield
  ensure
    File.define_singleton_method(method, original) if original
  end

  def journal_temporaries(store)
    (Dir.glob(store.path + '.tmp-*') + Dir.glob(File.join(File.dirname(store.path), '.journal-*.tmp'))).sort
  end

  def test_io_failures_short_write_flush_fsync_rename_and_owned_cleanup
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'io', values: join_values)
    bytes = File.binread(store.path)
    unrelated = store.path + '.tmp-unrelated'
    File.binwrite(unrelated, 'keep me')
    [:short, :write, :flush, :fsync].each do |fault|
      replacement = proc do |original|
        proc do |path, *args, &block|
          original.call(path, *args) do |file|
            logical = path.delete_prefix('\\\\?\\').tr('\\', '/')
            if logical.start_with?(store.path + '.tmp-') ||
                (File.dirname(logical)==File.dirname(store.path) && File.basename(logical).match?(/\A\.journal-[a-f0-9]{24}\.tmp\z/))
              if fault == :short
                write = file.method(:write)
                file.define_singleton_method(:write) { |data| write.call(data.byteslice(0, 5)) }
              else
                file.define_singleton_method(fault) { |*_| raise IOError, 'injected IO failure' }
              end
            end
            block.call(file)
          end
        end
      end
      with_file_fault(:open, replacement) do
        error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.claim(record['id']) }
      end
      equal(bytes, File.binread(store.path))
      equal([unrelated], journal_temporaries(store))
    end
    with_file_fault(:rename, proc { |_original| proc { |*_| raise Errno::EACCES } }) do
      error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.claim(record['id']) }
    end
    equal(bytes, File.binread(store.path))
    equal([unrelated], journal_temporaries(store))
    with_file_fault(:binread, proc { |_original| proc { |*_| raise IOError, 'disk' } }) do
      error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.list }
    end
    with_file_fault(:binread, proc { |_original| proc { |*_| raise NoMethodError, 'programmer bug' } }) do
      error(NoMethodError) { store.list }
    end
    equal(bytes, File.binread(store.path))
    equal('keep me', File.binread(unrelated))
    # A later healthy call still works; the failed claim never consumed the attempt.
    equal('attempted', store.claim(record['id'])['status'])
  end

  def test_unknown_parser_keyword_is_coded_incompatible_runtime
    original = JSON.method(:parse)
    JSON.define_singleton_method(:parse) { |*_, **_| raise ArgumentError, 'unknown keyword: allow_duplicate_key' }
    error(GameRoomTournaments::OperationJournal::Error, :incompatible_runtime) { journal }
    equal([], Dir.glob(File.join(@directory, '*')))
  ensure
    JSON.define_singleton_method(:parse, original) if original
  end

  def test_terminal_transition_matrix_and_dedup_never_reset_status
    store = journal
    %w[prepared attempted confirmed outside_window conflict].each do |from|
      %w[confirmed outside_window conflict].each do |target|
        intent = "#{from}-#{target}"
        record = store.prepare(kind: 'join', intent_id: intent, values: join_values)
        record = store.claim(record['id']) if from == 'attempted'
        if %w[confirmed outside_window conflict].include?(from)
          record = store.resolve(record['id'], status: from, evidence: {}, expected_revision: 1)
        end
        bytes = File.binread(store.path)
        duplicate = store.prepare(kind: 'join', intent_id: intent, values: join_values('replacement'))
        equal(record, duplicate)
        equal(bytes, File.binread(store.path))
        if %w[prepared attempted].include?(from) || from == target || target == 'conflict'
          resolved = store.resolve(record['id'], status: target, evidence: {'source' => from}, expected_revision: record['revision'])
          equal(record['revision'] + 1, resolved['revision'])
          equal(target, resolved['status'])
          equal(record['values'], resolved['values'])
          equal(nil, journal.claim(record['id']))
        else
          error(GameRoomTournaments::OperationJournal::Conflict, :terminal_conflict) do
            store.resolve(record['id'], status: target, evidence: {}, expected_revision: record['revision'])
          end
          equal(bytes, File.binread(store.path))
        end
      end
    end
  end

  def test_lock_failures_exclusive_temporary_collision_and_commit_order
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'order', values: join_values)
    bytes = File.binread(store.path)
    with_file_fault(:open, proc do |original|
      proc do |path, *args, &block|
        original.call(path, *args) do |file|
          file.define_singleton_method(:flock) { |_| false } if path.end_with?('.lock')
          block.call(file)
        end
      end
    end) do
      error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.claim(record['id']) }
    end
    equal(bytes, File.binread(store.path))
    collision = store.path + '.tmp-collision'
    collision = File.join(File.dirname(store.path), '.journal-collision.tmp') if collision.bytesize>=260
    File.binwrite(collision, 'not mine')
    original_hex = SecureRandom.method(:hex)
    SecureRandom.define_singleton_method(:hex) { |_| 'collision' }
    begin
      error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.claim(record['id']) }
      equal('not mine', File.binread(collision))
      equal(bytes, File.binread(store.path))
    ensure
      SecureRandom.define_singleton_method(:hex, original_hex)
    end
    events = []
    with_file_fault(:open, proc do |original|
      proc do |path, *args, &block|
        original.call(path, *args) do |file|
          methods = path.end_with?('.lock') ? [:flock] : [:write, :flush, :fsync]
          methods.each do |method|
            call = file.method(method)
            file.define_singleton_method(method) { |*values| events << method; call.call(*values) }
          end
          block.call(file)
        end
      end
    end) do
      with_file_fault(:rename, proc do |original|
        proc { |*args| events << :rename; original.call(*args) }
      end) { store.claim(record['id']) }
    end
    equal([:flock, :write, :flush, :fsync, :rename, :flock], events)
  end

  def test_uncertain_rename_failure_does_not_enable_second_claim
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'uncertain', values: join_values)
    with_file_fault(:rename, proc do |original|
      proc { |*args| original.call(*args); raise IOError, 'failure after commit' }
    end) do
      error(GameRoomTournaments::OperationJournal::Error, :journal_io_error) { store.claim(record['id']) }
    end
    equal('attempted', journal.fetch(record['id'])['status'])
    equal(nil, journal.claim(record['id']))
    equal([], journal_temporaries(store))
  end

  def test_prepare_captures_intent_before_waiting_for_lock
    store = journal
    intent = 'original-intent'
    original_open = File.method(:open)
    File.define_singleton_method(:open) do |path, *args, &block|
      intent.replace('mutated-intent') if path.end_with?('.lock')
      original_open.call(path, *args, &block)
    end
    record = store.prepare(kind: 'join', intent_id: intent, values: join_values)
    equal('original-intent', record['intent_id'])
    equal('mutated-intent', intent)
  ensure
    File.define_singleton_method(:open, original_open) if original_open
  end

  def test_no_clock_and_all_reads_are_snapshot_only
    store = journal
    record = store.prepare(kind: 'join', intent_id: 'clock', values: join_values)
    original_now = Time.method(:now)
    Time.define_singleton_method(:now) { raise 'Journal must not consult a clock' }
    bytes = File.binread(store.path)
    frozen_tree(store.list)
    frozen_tree(store.fetch(record['id']))
    frozen_tree(store.find(kind: 'join', intent_id: 'clock'))
    equal(bytes, File.binread(store.path))
    equal(record, store.prepare(kind: 'join', intent_id: 'clock', values: join_values('second')))
    equal(bytes, File.binread(store.path))
    equal('attempted', store.claim(record['id'])['status'])
    equal('confirmed', store.resolve(record['id'], status: 'confirmed', evidence: {}, expected_revision: 2)['status'])
    equal(%i[backend_identity claim fetch find list owner path prepare resolve trim_confirmed_presence], store.class.public_instance_methods(false).sort)
  ensure
    Time.define_singleton_method(:now, original_now) if original_now
  end

  def test_corrupt_evidence_and_payload_limits_checked_on_every_read
    store = journal
    record = store.prepare(kind: 'publication', intent_id: 'disk', values: publication)
    record = store.resolve(record['id'], status: 'confirmed', evidence: {}, expected_revision: 1)
    good = JSON.parse(File.binread(store.path))
    oversized_text = 'x' * (16_385 - JSON.generate({'text' => ''}).bytesize)
    bad_values = [{'__metadata' => 1}, {'nested' => [{'__private' => 2}]}, {'value' => 2**63}, {'text' => oversized_text}]
    bad_values.each do |value|
      document = Marshal.load(Marshal.dump(good))
      document['operations'][0]['evidence'] = value
      bytes = JSON.generate(document).b
      File.binwrite(store.path, bytes)
      error(GameRoomTournaments::OperationJournal::Corrupt) { store.find(kind: 'publication', intent_id: 'disk') }
      equal(bytes, File.binread(store.path))
    end
    good['operations'][0]['values']['rules'] = 'x' * 160_000
    bytes = JSON.generate(good).b
    File.binwrite(store.path, bytes)
    error(GameRoomTournaments::OperationJournal::Corrupt) { store.list }
    equal(bytes, File.binread(store.path))
  end

  def test_claim_captures_id_before_waiting_for_lock
    store = journal
    first = store.prepare(kind: 'join', intent_id: 'first', values: join_values)
    second = store.prepare(kind: 'join', intent_id: 'second', values: join_values)
    id = first['id'].dup
    with_file_fault(:open, proc do |original|
      proc do |path, *args, &block|
        id.replace(second['id']) if path.end_with?('.lock')
        original.call(path, *args, &block)
      end
    end) { equal(first['id'], store.claim(id)['id']) }
    equal('prepared', store.fetch(second['id'])['status'])
  end

  def test_resolve_captures_id_and_status_before_waiting_for_lock
    store = journal
    first = store.prepare(kind: 'join', intent_id: 'first', values: join_values)
    second = store.prepare(kind: 'join', intent_id: 'second', values: join_values)
    id, status = first['id'].dup, 'confirmed'
    with_file_fault(:open, proc do |original|
      proc do |path, *args, &block|
        if path.end_with?('.lock')
          id.replace(second['id']); status.replace('conflict')
        end
        original.call(path, *args, &block)
      end
    end) do
      resolved = store.resolve(id, status: status, evidence: {}, expected_revision: 1)
      equal(first['id'], resolved['id'])
      equal('confirmed', resolved['status'])
    end
    equal('prepared', store.fetch(second['id'])['status'])
  end

  def run
    @assertions = 0
    tests = methods.grep(/^test_/).sort
    if ENV['OPERATION_JOURNAL_TEST']
      tests = tests.select { |name| name.to_s.include?(ENV['OPERATION_JOURNAL_TEST']) }
    end
    raise 'Brak wybranych scenariuszy' if tests.empty?
    tests.each do |name|
      Dir.mktmpdir('tournament-operation-journal-', ENV.fetch('TMPDIR')) do |directory|
        @directory = directory.tr('\\', '/')
        send(name)
      end
      puts "PASS #{name}"
    end
    puts "PASS #{tests.length} scenariuszy, #{@assertions} asercji; Ruby #{RUBY_VERSION}; JSON #{JSON::VERSION}"
  end
end

TournamentOperationJournalTest.new.run
