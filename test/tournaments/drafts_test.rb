# encoding: UTF-8
require "tmpdir"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "timeout"

source = File.expand_path("../../lib/tournaments/drafts.rb", __dir__)
require source if File.file?(source)

# Wstrzyknięcie awarii dotyczy tylko plików danego testu i bieżącego wątku.
module TournamentDraftFileProbe
  def write(*args)
    probe = Thread.current[:tournament_draft_probe]
    if probe && path.start_with?(probe[:path] + ".v1-") && probe[:fail] == :backup_short_write
      return super(args.first[0, 10])
    end
    if probe && path.start_with?(probe[:path] + ".v1-") && probe[:fail] == :backup_write
      super(args.first[0, 10])
      raise Errno::ENOSPC, "Testowa awaria zapisu kopii"
    end
    if probe && path.start_with?(probe[:path] + ".tmp-") && probe[:fail] == :write
      super(args.first[0, 10])
      raise Errno::ENOSPC, "Testowa awaria zapisu"
    end
    super
  end

  def flush
    probe = Thread.current[:tournament_draft_probe]
    probe[:events] << :flush if probe && path.start_with?(probe[:path] + ".tmp-")
    if probe && path.start_with?(probe[:path] + ".v1-")
      probe[:events] << :backup_flush
      raise IOError, "Testowa awaria flush kopii" if probe[:fail] == :backup_flush
    end
    super
  end

  def flock(operation)
    probe = Thread.current[:tournament_draft_probe]
    if probe && path == probe[:path] + ".lock" && operation == File::LOCK_EX && probe[:fail] == :lock
      return false
    end
    super
  end

  def fsync
    probe = Thread.current[:tournament_draft_probe]
    if probe && path.start_with?(probe[:path] + ".tmp-")
      probe[:events] << :fsync
      raise IOError, "Testowa awaria fsync" if probe[:fail] == :fsync
    end
    if probe && path.start_with?(probe[:path] + ".v1-")
      probe[:events] << :backup_fsync
      raise IOError, "Testowa awaria fsync kopii" if probe[:fail] == :backup_fsync
    end
    super
  end
end

module TournamentDraftRenameProbe
  def open(path, *args, **kwargs, &block)
    probe = Thread.current[:tournament_draft_probe]
    if probe && path.start_with?(probe[:path] + ".v1-") && probe[:fail] == :backup_open
      raise Errno::EACCES, "Testowa odmowa utworzenia kopii"
    end
    super
  end

  def binread(path, *args)
    probe = Thread.current[:tournament_draft_probe]
    probe[:reads] << args.first if probe && probe[:reads] && path == probe[:path]
    raise probe[:read_error], "Testowa awaria odczytu" if probe && probe[:read_error] && path == probe[:path]
    super
  end

  def rename(source, destination)
    probe = Thread.current[:tournament_draft_probe]
    if probe && destination == probe[:path]
      probe[:events] << :rename
      probe[:before_rename].call(source) if probe[:before_rename]
      raise Errno::EACCES, "Testowa awaria rename" if probe[:fail] == :rename
    end
    result = super
    if probe && destination == probe[:path] && probe[:fail] == :rename_after
      raise IOError, "Testowa utrata potwierdzenia po skutecznym rename"
    end
    result
  end
end
File.prepend(TournamentDraftFileProbe)
File.singleton_class.prepend(TournamentDraftRenameProbe)

module TournamentDraftClockProbe
  def now(*args, **kwargs)
    Thread.current[:tournament_draft_time] || super
  end
end
Time.singleton_class.prepend(TournamentDraftClockProbe)

class TournamentDraftsTest
  Program = Struct.new(:data_path)

  def assert(value, message = "Niespełniona asercja")
    @assertions += 1
    raise message unless value
  end

  def equal(expected, actual)
    assert(expected == actual, "Oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def raises(type)
    @assertions += 1
    begin
      yield
    rescue type => error
      return error
    end
    raise "Oczekiwano błędu #{type}"
  end

  def attributes
    {"name" => "Turniej próbny", "game_id" => "chess", "game_options" => {"custom" => [true, nil, 3, "żółć"]},
      "format" => nil, "rematch" => nil}
  end

  def store(owner = "Tester")
    GameRoomTournaments::Drafts.new(@program, owner: owner)
  end

  def data_file(owner = "tester")
    File.join(@directory, "tournament-drafts-#{Digest::SHA256.hexdigest(owner)}.json")
  end

  def test_create_persists_a_local_draft
    assert(defined?(GameRoomTournaments::Drafts), "Brak magazynu szkiców")
    drafts = store
    equal([], drafts.list)
    equal(nil, drafts.fetch("nieistniejący"))
    before = Time.now.to_i
    record = drafts.create(attributes)
    attributes.each { |key, value| equal(value, record[key]) }
    assert(record["id"].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/))
    equal("tester", record["owner"])
    equal(1, record["revision"])
    equal("draft", record["status"])
    assert(record["created_at"].is_a?(Integer) && record["created_at"].between?(before, Time.now.to_i))
    equal(record["created_at"], record["updated_at"])
    equal(record, store.fetch(record["id"]))
    equal([record], store.list)
    # Nowy zapis zawiera cztery dodatkowe pola, więc wymaga schematu 2.
    equal(2, JSON.parse(File.binread(data_file))["schema_version"])
  end

  def details
    {"participants" => ["Żółć", "ALFA", "Gracz 3"],
      "windows" => [{"date" => "2026-10-01", "start" => "23:30", "end_date" => "2026-10-02", "end" => "01:00"}],
      "players_per_match" => 3, "pairing" => "balanced_cycle"}
  end

  def test_schema_two_persists_details_and_defaults_without_aliasing
    input = attributes.merge(details)
    expected = JSON.parse(JSON.generate(input))
    record = store.create(input)
    expected.each { |key, value| equal(value, record[key]) }
    equal(2, JSON.parse(File.binread(data_file))["schema_version"])
    equal(record, store.fetch(record["id"]))
    record["participants"].first.replace("Zmiana")
    record["windows"].first["end"].replace("02:00")
    equal(expected, input)
    details.each { |key, value| equal(value, store.fetch(record["id"])[key]) }
    changes = {"participants" => ["Nowy", "Drugi"], "pairing" => "all_combinations", "players_per_match" => 2}
    changed = store.update(record["id"], changes, expected_revision: 1)
    changes.each { |key, value| equal(value, changed[key]) }
    equal(details["windows"], changed["windows"])
    changed["participants"].clear
    equal(["Nowy", "Drugi"], changes["participants"])
    equal(["Nowy", "Drugi"], store.fetch(record["id"])["participants"])
    defaults = store.create(attributes)
    GameRoomTournaments::DraftDetails::DEFAULTS.each { |key, value| equal(value, defaults.fetch(key)) }
    defaults["participants"] << "Tylko kopia"
    equal([], store.fetch(defaults["id"])["participants"])
  end

  def test_details_validation_preserves_file_and_error_codes
    record = store.create(attributes.merge(details))
    bytes = File.binread(data_file)
    stamp = File.mtime(data_file)
    {
      "participants" => [nil, ["A", "a"], Array.new(257) { |i| "Gracz #{i}" }],
      "windows" => [nil, [details["windows"].first] * 2, Array.new(367, {})],
      "players_per_match" => [1, 9, 2.0, "2"],
      "pairing" => ["swiss", :balanced_cycle, false]
    }.each do |field, values|
      values.each do |value|
        [-> { store.create(attributes.merge(field => value)) },
          -> { store.update(record["id"], {field => value}, expected_revision: 1) }].each do |operation|
          error = raises(GameRoomTournaments::Drafts::Invalid, &operation)
          equal("invalid_#{field}".to_sym, error.code)
          equal(bytes, File.binread(data_file))
          equal(stamp, File.mtime(data_file))
        end
      end
    end
  end

  # Wyłącznie syntetyczny zapis starego schematu; żadnych danych profilu.
  def legacy_document
    first = attributes.merge("id" => "00000000-0000-4000-8000-000000000001", "owner" => "tester",
      "revision" => 7, "created_at" => 100, "updated_at" => 500, "status" => "draft")
    second = first.merge("id" => "00000000-0000-4000-8000-000000000002", "name" => "Drugi", "revision" => 3)
    {"schema_version" => 1, "owner" => "tester", "drafts" => [first, second]}
  end

  def put_legacy(document = legacy_document)
    bytes = " \r\n" + JSON.pretty_generate(document) + "\r\n "
    File.binwrite(data_file, bytes)
    bytes.b
  end

  def test_legacy_read_only_adds_independent_defaults_in_memory
    document = legacy_document
    bytes = put_legacy(document)
    stamp = File.mtime(data_file)
    drafts = store
    records = drafts.list
    equal(2, records.size)
    records.zip(document["drafts"]).each do |record, old|
      old.each { |key, value| equal(value, record.fetch(key)) }
      GameRoomTournaments::DraftDetails::DEFAULTS.each { |key, value| equal(value, record.fetch(key)) }
    end
    records.first["participants"] << "Tylko kopia"
    records.first["windows"] << {}
    equal([], records.last["participants"])
    equal([], records.last["windows"])
    equal([], drafts.fetch(records.first["id"])["participants"])
    equal(bytes, File.binread(data_file))
    equal(stamp, File.mtime(data_file))
    equal([File.basename(data_file), File.basename(data_file) + ".lock"].sort, Dir.children(@directory).sort)
  end

  def backup_path(bytes)
    "#{data_file}.v1-#{Digest::SHA256.hexdigest(bytes)}.bak"
  end

  def test_legacy_edit_backs_up_exact_bytes_before_replacement
    document = legacy_document
    bytes = put_legacy(document)
    old, other = document["drafts"]
    copied = backup_path(bytes)
    probe = {path: data_file, events: [], before_rename: ->(temporary) {
      equal(bytes, File.binread(data_file))
      assert(File.file?(copied), "Brak kopii v1 przed zastąpieniem oryginału")
      equal(bytes, File.binread(copied))
      equal(2, JSON.parse(File.binread(temporary))["schema_version"])
    }}
    Thread.current[:tournament_draft_probe] = probe
    changed = store.update(old["id"], details, expected_revision: old["revision"])
    equal([:flush, :fsync, :backup_flush, :backup_fsync, :rename], probe[:events])
    equal(8, changed["revision"])
    details.each { |key, value| equal(value, changed[key]) }
    old.each { |key, value| equal(value, changed[key]) unless %w[revision updated_at].include?(key) }
    other.each { |key, value| equal(value, store.fetch(other["id"])[key]) }
    equal([changed["id"], other["id"]], store.list.map { |item| item["id"] })
    equal(bytes, File.binread(copied))
    equal(2, JSON.parse(File.binread(data_file))["schema_version"])
    stamp = File.mtime(copied)
    Thread.current[:tournament_draft_probe] = nil
    store.update(changed["id"], {"name" => "Następna zmiana"}, expected_revision: 8)
    equal(stamp, File.mtime(copied))
    equal(bytes, File.binread(copied))
    equal([File.basename(copied)], Dir.glob("*.bak", base: @directory))
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_legacy_retry_after_failed_rename_reuses_backup_without_overwriting
    bytes = put_legacy
    old = legacy_document["drafts"].first
    drafts = store
    probe = {path: data_file, events: [], fail: :rename}
    Thread.current[:tournament_draft_probe] = probe
    raises(Errno::EACCES) { drafts.update(old["id"], details, expected_revision: 7) }
    equal(bytes, File.binread(data_file))
    equal(bytes, File.binread(backup_path(bytes)))
    stamp = File.mtime(backup_path(bytes))
    equal([], Dir.glob("*.tmp-*", base: @directory))
    probe[:fail] = nil
    probe[:events].clear
    changed = drafts.update(old["id"], details, expected_revision: 7)
    equal(8, changed["revision"])
    equal(stamp, File.mtime(backup_path(bytes)))
    equal(bytes, File.binread(backup_path(bytes)))
    equal([:flush, :fsync, :backup_flush, :backup_fsync, :rename], probe[:events])
    equal(2, JSON.parse(File.binread(data_file))["schema_version"])
    equal([File.basename(backup_path(bytes))], Dir.glob("*.bak", base: @directory))
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_legacy_backup_failures_block_all_writes_and_allow_safe_retry
    bytes = put_legacy
    old = legacy_document["drafts"].first
    drafts = store
    {backup_write: Errno::ENOSPC, backup_open: Errno::EACCES, backup_flush: IOError, backup_fsync: IOError}.each do |stage, error|
      probe = {path: data_file, events: [], fail: stage}
      Thread.current[:tournament_draft_probe] = probe
      [-> { drafts.create(attributes) }, -> { drafts.update(old["id"], details, expected_revision: 7) },
        -> { drafts.delete(old["id"], expected_revision: 7) }].each do |operation|
        raises(error, &operation)
        equal(bytes, File.binread(data_file))
        equal([], Dir.glob("*.tmp-*", base: @directory))
        assert(!File.exist?(backup_path(bytes)), "Pozostała nieukończona nowa kopia")
        assert(!probe[:events].include?(:rename), "Zastąpienie bez trwałej kopii")
        equal(7, drafts.fetch(old["id"])["revision"])
      end
    end
    Thread.current[:tournament_draft_probe] = nil
    changed = drafts.update(old["id"], details, expected_revision: 7)
    equal(8, changed["revision"])
    equal(bytes, File.binread(backup_path(bytes)))
    equal(changed, store.fetch(old["id"]))
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_legacy_short_backup_write_cannot_replace_original
    bytes = put_legacy
    Thread.current[:tournament_draft_probe] = {path: data_file, events: [], fail: :backup_short_write}
    raises(IOError) { store.create(attributes) }
    equal(bytes, File.binread(data_file))
    assert(!File.exist?(backup_path(bytes)))
    equal([], Dir.glob("*.tmp-*", base: @directory))
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_uncertain_rename_keeps_committed_state_and_never_repeats_the_write
    [:create, :update, :delete].each do |operation|
      bytes = put_legacy
      old, other = legacy_document["drafts"]
      drafts = store
      probe = {path: data_file, events: [], fail: :rename_after}
      Thread.current[:tournament_draft_probe] = probe
      raises(IOError) do
        case operation
        when :create then drafts.create(attributes.merge(details))
        when :update then drafts.update(old["id"], details, expected_revision: 7)
        when :delete then drafts.delete(old["id"], expected_revision: 7)
        end
      end
      equal(1, probe[:events].count(:rename))
      equal(2, JSON.parse(File.binread(data_file))["schema_version"])
      equal(bytes, File.binread(backup_path(bytes)))
      equal([], Dir.glob("*.tmp-*", base: @directory))
      records = drafts.list
      equal(operation == :create ? 3 : (operation == :delete ? 1 : 2), records.size)
      other.each { |key, value| equal(value, drafts.fetch(other["id"])[key]) }
      if operation == :update
        equal(8, drafts.fetch(old["id"])["revision"])
        equal(details["participants"], drafts.fetch(old["id"])["participants"])
      elsif operation == :delete
        equal(nil, drafts.fetch(old["id"]))
      else
        equal(details["participants"], records.last["participants"])
      end
      committed = File.binread(data_file)
      unless operation == :create
        raises(GameRoomTournaments::Drafts::Conflict) { drafts.update(old["id"], {}, expected_revision: 7) }
        raises(GameRoomTournaments::Drafts::Conflict) { drafts.delete(old["id"], expected_revision: 7) }
        equal(committed, File.binread(data_file))
      end
      Thread.current[:tournament_draft_probe] = nil
    end
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_legacy_existing_backup_is_never_overwritten_or_removed
    bytes = put_legacy
    old = legacy_document["drafts"].first
    backup = backup_path(bytes)
    ["", "Wcześniejsza kopia", bytes + "nadmiar"].each do |previous|
      File.binwrite(backup, previous)
      stamp = File.mtime(backup)
      [-> { store.create(attributes) }, -> { store.update(old["id"], details, expected_revision: 7) },
        -> { store.delete(old["id"], expected_revision: 7) }].each do |operation|
        raises(IOError, &operation)
        equal(bytes, File.binread(data_file))
        equal(previous.b, File.binread(backup))
        equal(stamp, File.mtime(backup))
        equal([], Dir.glob("*.tmp-*", base: @directory))
      end
    end
    File.binwrite(backup, bytes)
    stamp = File.mtime(backup)
    [:backup_flush, :backup_fsync].each do |stage|
      Thread.current[:tournament_draft_probe] = {path: data_file, events: [], fail: stage}
      raises(IOError) { store.delete(old["id"], expected_revision: 7) }
      equal(bytes, File.binread(data_file))
      equal(bytes, File.binread(backup))
      equal(stamp, File.mtime(backup))
    end
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_legacy_distinct_snapshots_get_distinct_immutable_backups
    snapshots = []
    2.times do |index|
      document = legacy_document
      document["drafts"].first["name"] = "Wersja #{index}"
      bytes = put_legacy(document)
      store.create(attributes)
      snapshots << [backup_path(bytes), bytes, File.mtime(backup_path(bytes))]
      snapshots.each do |path, expected, stamp|
        equal(expected, File.binread(path))
        equal(stamp, File.mtime(path))
      end
    end
    equal(snapshots.map { |path, _, _| File.basename(path) }.sort, Dir.glob("*.bak", base: @directory).sort)
  end

  def test_legacy_create_and_delete_preserve_every_other_record
    bytes = put_legacy
    old_records = legacy_document["drafts"]
    created = store.create(attributes.merge(details))
    equal(1, created["revision"])
    old_records.zip(store.list).each do |old, current|
      old.each { |key, value| equal(value, current[key]) }
      GameRoomTournaments::DraftDetails::DEFAULTS.each { |key, value| equal(value, current[key]) }
    end
    equal(3, store.list.size)
    equal(bytes, File.binread(backup_path(bytes)))
    put_legacy
    first, second = old_records
    equal(true, store.delete(first["id"], expected_revision: 7))
    equal(1, store.list.size)
    second.each { |key, value| equal(value, store.fetch(second["id"])[key]) }
    equal(2, JSON.parse(File.binread(data_file))["schema_version"])
    equal(bytes, File.binread(backup_path(bytes)))
    one = legacy_document.merge("drafts" => [first])
    one_bytes = put_legacy(one)
    equal(true, store.delete(first["id"], expected_revision: 7))
    equal([], store.list)
    equal(one_bytes, File.binread(backup_path(one_bytes)))
    empty_bytes = put_legacy(legacy_document.merge("drafts" => []))
    equal([], store.list)
    assert(!File.exist?(backup_path(empty_bytes)))
    store.create(attributes)
    equal(empty_bytes, File.binread(backup_path(empty_bytes)))
    equal(1, store.list.size)
  end

  def test_legacy_corruption_is_validated_before_defaults_or_backups
    document = legacy_document
    first, second = document["drafts"]
    variants = []
    second.keys.each do |key|
      variants << document.merge("drafts" => [first, second.reject { |field, _| field == key }])
    end
    GameRoomTournaments::DraftDetails::DEFAULTS.each do |key, value|
      variants << document.merge("drafts" => [first, second.merge(key => value)])
    end
    {"id" => first["id"], "owner" => "obcy", "revision" => 0, "created_at" => -1,
      "updated_at" => 99, "status" => "published", "name" => "", "game_id" => "CHESS",
      "game_options" => [], "format" => "swiss", "rematch" => 1}.each do |field, value|
      variants << document.merge("drafts" => [first, second.merge(field => value)])
    end
    [nil, true, "1", 1.0, 0, -1, 2, 3].each { |value| variants << document.merge("schema_version" => value) }
    variants << document.merge("drafts" => [first, nil])
    variants << document.merge("drafts" => [first, second.merge("extra" => true)])
    variants << document.merge("extra" => true)
    variants << document.merge("owner" => "obcy")
    variants.each do |invalid|
      bytes = put_legacy(invalid)
      stamp = File.mtime(data_file)
      [-> { store.list }, -> { store.fetch(first["id"]) }, -> { store.create(attributes) },
        -> { store.update(first["id"], details, expected_revision: 7) },
        -> { store.delete(first["id"], expected_revision: 7) }].each do |operation|
        raises(GameRoomTournaments::Drafts::Corrupt, &operation)
        equal(bytes, File.binread(data_file))
        equal(stamp, File.mtime(data_file))
        equal([], Dir.glob("*.bak", base: @directory))
        equal([], Dir.glob("*.tmp-*", base: @directory))
      end
    end
  end

  def test_legacy_invalid_edits_and_stale_revisions_do_not_migrate
    bytes = put_legacy
    first = legacy_document["drafts"].first
    [-> { store.update(first["id"], {"participants" => ["A", "a"]}, expected_revision: 7) },
      -> { store.create(attributes.merge("pairing" => "swiss")) }].each do |operation|
      raises(GameRoomTournaments::Drafts::Invalid, &operation)
      equal(bytes, File.binread(data_file))
    end
    raises(GameRoomTournaments::Drafts::Conflict) { store.delete(first["id"], expected_revision: 6) }
    raises(GameRoomTournaments::Drafts::Conflict) { store.update(first["id"], details, expected_revision: 6) }
    equal(bytes, File.binread(data_file))
    equal([], Dir.glob("*.bak", base: @directory))
  end

  def test_legacy_migration_expansion_cannot_exceed_the_file_limit
    document = legacy_document
    maximum = GameRoomTournaments::Drafts::MAX_FILE_BYTES
    document["drafts"].first["game_id"] += "a" * (maximum - JSON.generate(document).bytesize)
    bytes = JSON.generate(document).b
    equal(maximum, bytes.bytesize)
    File.binwrite(data_file, bytes)
    first, second = document["drafts"]
    equal(2, store.list.size)
    error = raises(GameRoomTournaments::Drafts::Invalid) { store.update(first["id"], {}, expected_revision: 7) }
    equal(:invalid_options, error.code)
    equal(bytes, File.binread(data_file))
    equal([], Dir.glob("*.bak", base: @directory))
    equal([], Dir.glob("*.tmp-*", base: @directory))
    equal(true, store.delete(first["id"], expected_revision: 7))
    equal(bytes, File.binread(backup_path(bytes)))
    equal(1, store.list.size)
    second.each { |key, value| equal(value, store.fetch(second["id"])[key]) }
  end

  def test_details_limits_round_trip_with_order_and_allow_clearing
    maximum_details = details.merge("participants" => Array.new(256) { |i| "#{i}-" + "ą" * 60 },
      "windows" => Array.new(366) { |i|
        date = (Date.new(2024, 1, 1, Date::GREGORIAN) + i).strftime("%Y-%m-%d")
        {"date" => date, "start" => "00:00", "end_date" => date, "end" => "23:59"}
      }.reverse, "players_per_match" => 8)
    record = store.create(attributes.merge(maximum_details))
    maximum_details.each { |key, value| equal(value, record[key]); equal(value, store.fetch(record["id"])[key]) }
    empty = {"participants" => [], "windows" => [], "players_per_match" => nil, "pairing" => nil}
    changed = store.update(record["id"], empty, expected_revision: 1)
    empty.each { |key, value| equal(value, changed[key]) }
    equal(changed, store.fetch(record["id"]))
  end

  def test_legacy_concurrent_migration_uses_the_existing_lock
    bytes = put_legacy
    originals = store.list
    threads = 6.times.map { |index| Thread.new { store.create(attributes.merge("name" => "Równolegle #{index}")) } }
    threads.each { |thread| assert(thread.join(20), "Zablokowana migracja"); thread.value }
    equal(8, store.list.size)
    equal(originals, store.list.first(2))
    equal(bytes, File.binread(backup_path(bytes)))
    equal([File.basename(backup_path(bytes))], Dir.glob("*.bak", base: @directory))
    equal([], Dir.glob("*.tmp-*", base: @directory))
  end

  def test_details_write_boundary_rejects_corruption_after_legacy_read
    bytes = put_legacy
    first = legacy_document["drafts"].first
    klass = Class.new(GameRoomTournaments::Drafts) do
      private
      def read
        super.tap { |document| document["drafts"].last["participants"] = ["A", "a"] }
      end
    end
    drafts = klass.new(@program, owner: "Tester")
    [-> { drafts.create(attributes) }, -> { drafts.update(first["id"], details, expected_revision: 7) },
      -> { drafts.delete(first["id"], expected_revision: 7) }].each do |operation|
      raises(GameRoomTournaments::Drafts::Corrupt, &operation)
      equal(bytes, File.binread(data_file))
      equal([], Dir.glob("*.bak", base: @directory))
    end
  end

  def test_update_and_delete_require_the_current_revision
    drafts = store
    first = drafts.create(attributes)
    other = store.create(attributes.merge("name" => "Drugi"))
    changed = drafts.update(first["id"], {"name" => "Nowa nazwa", "rematch" => false}, expected_revision: 1)
    equal(2, changed["revision"])
    equal("Nowa nazwa", changed["name"])
    equal(false, changed["rematch"])
    equal(first["created_at"], changed["created_at"])
    equal(first["game_options"], changed["game_options"])
    equal(first["id"], changed["id"])
    equal("draft", changed["status"])
    assert(changed["updated_at"] >= first["updated_at"])
    bytes = File.binread(data_file)
    raises(GameRoomTournaments::Drafts::Conflict) { store.update(first["id"], {"name" => "Stare"}, expected_revision: 1) }
    raises(GameRoomTournaments::Drafts::Conflict) { store.delete(first["id"], expected_revision: 1) }
    [nil, "2", 2.0, true, -1].each do |revision|
      raises(GameRoomTournaments::Drafts::Conflict) { drafts.delete(first["id"], expected_revision: revision) }
      raises(GameRoomTournaments::Drafts::Conflict) { drafts.update(first["id"], {}, expected_revision: revision) }
    end
    equal(bytes, File.binread(data_file))
    equal(true, store.delete(first["id"], expected_revision: 2))
    equal([other], drafts.list)
    equal(nil, drafts.fetch(first["id"]))
    bytes = File.binread(data_file)
    raises(GameRoomTournaments::Drafts::Conflict) { drafts.delete(first["id"], expected_revision: 2) }
    raises(GameRoomTournaments::Drafts::Conflict) { drafts.update(first["id"], {}, expected_revision: 2) }
    equal(bytes, File.binread(data_file))
  end

  def test_update_preserves_time_when_clock_moves_before_creation
    verify_updates_with_clock([[1_000, 2_000], [3_000, 3_000]])
  end

  def test_update_preserves_time_when_clock_moves_before_last_edit
    verify_updates_with_clock([[3_000, 3_000], [2_500, 3_000], [4_000, 4_000]])
  end

  def verify_updates_with_clock(steps)
    previous_time = Thread.current[:tournament_draft_time]
    Thread.current[:tournament_draft_time] = Time.at(2_000)
    record = store.create(attributes)
    equal(2_000, record["created_at"])
    equal(2_000, record["updated_at"])
    equal(1, record["revision"])
    steps.each do |clock, expected_time|
      Thread.current[:tournament_draft_time] = Time.at(clock)
      previous_revision = record["revision"]
      name = "Edycja przy #{clock}"
      record = store.update(record["id"], {"name" => name}, expected_revision: previous_revision)
      equal(expected_time, record["updated_at"])
      equal(2_000, record["created_at"])
      equal(previous_revision + 1, record["revision"])
      equal(name, record["name"])
      equal(record, store.fetch(record["id"]))
      equal([record], store.list)
      bytes = File.binread(data_file)
      raises(GameRoomTournaments::Drafts::Conflict) do
        store.update(record["id"], {"name" => "Stara rewizja"}, expected_revision: previous_revision)
      end
      equal(bytes, File.binread(data_file))
    end
  ensure
    Thread.current[:tournament_draft_time] = previous_time
  end

  def test_attribute_validation_preserves_the_file
    drafts = store
    record = drafts.create(attributes)
    bytes = File.binread(data_file)
    stamp = File.mtime(data_file)
    invalid = {
      "name" => [:invalid_name, [nil, 3, "", " \t ", "x" * 121, "a\nb", "a\rb", "a\u0000b", "a\u2028b", "a\u2029b", "\xff".force_encoding("UTF-8"), "\xff".b, "abc".encode("UTF-16LE")]],
      "game_id" => [:invalid_game, [nil, "", "Chess", "chess-1", "../chess", "ą", "chess\n", 1]],
      "format" => [:invalid_format, [true, "swiss", :round_robin]],
      "rematch" => [:invalid_rematch, [1, 0, "false", [], {}]]
    }
    invalid.each do |field, (code, values)|
      values.each do |value|
        error = raises(GameRoomTournaments::Drafts::Invalid) { drafts.create(attributes.merge(field => value)) }
        equal(code, error.code)
        error = raises(GameRoomTournaments::Drafts::Invalid) { drafts.update(record["id"], {field => value}, expected_revision: 1) }
        equal(code, error.code)
        equal(bytes, File.binread(data_file))
        equal(stamp, File.mtime(data_file))
      end
    end
    [nil, [], {name: "Symbol"}, {"owner" => "inne"}, {"id" => "fałszywe"}, {"revision" => 99}, {"scheduled_at" => 3}].each do |value|
      raises(GameRoomTournaments::Drafts::Invalid) { drafts.update(record["id"], value, expected_revision: 1) }
      raises(GameRoomTournaments::Drafts::Invalid) { drafts.create(value) }
      equal(bytes, File.binread(data_file))
    end
    %w[name game_id game_options].each do |key|
      raises(GameRoomTournaments::Drafts::Invalid) { drafts.create(attributes.reject { |field, _| field == key }) }
      equal(bytes, File.binread(data_file))
    end
    other = store("Nowy")
    raises(GameRoomTournaments::Drafts::Invalid) { other.create(attributes.merge("name" => "")) }
    assert(!File.exist?(data_file("nowy")))
    equal("ą" * 120, drafts.create(attributes.merge("name" => "ą" * 120))["name"])
    %w[round_robin groups_knockout].each do |format|
      equal(format, drafts.create(attributes.merge("format" => format, "rematch" => true))["format"])
    end
    short = attributes.reject { |key, _| %w[format rematch].include?(key) }
    result = drafts.create(short)
    assert(result.key?("format") && result.key?("rematch"))
    equal(nil, result["format"])
    equal(nil, result["rematch"])
  end

  def test_options_are_bounded_json_without_coercion
    drafts = store
    record = drafts.create(attributes)
    bytes = File.binread(data_file)
    cycle = {}; cycle["self"] = cycle
    deep = {}; cursor = deep
    8.times { cursor["next"] = {}; cursor = cursor["next"] }
    bad_values = [nil, [], {symbol: 1}, {"x" => :symbol}, {"x" => Object.new}, {"x" => Float::NAN},
      {"x" => Float::INFINITY}, {"x" => -Float::INFINITY}, {"x" => "\xff".force_encoding("UTF-8")},
      {"x" => "x" * 65_536}, {"x" => Array.new(4096, 0)}, cycle, deep]
    bad_values.each do |options|
      error = raises(GameRoomTournaments::Drafts::Invalid) { drafts.create(attributes.merge("game_options" => options)) }
      equal(:invalid_options, error.code)
      error = raises(GameRoomTournaments::Drafts::Invalid) { drafts.update(record["id"], {"game_options" => options}, expected_revision: 1) }
      equal(:invalid_options, error.code)
      equal(bytes, File.binread(data_file))
    end
    boundary = {"x" => "x" * (65_536 - 8)}
    equal(65_536, JSON.generate(boundary).bytesize)
    equal(boundary, drafts.create(attributes.merge("game_options" => boundary))["game_options"])
    eight = {}; cursor = eight
    7.times { cursor["next"] = {}; cursor = cursor["next"] }
    equal(eight, drafts.create(attributes.merge("game_options" => eight))["game_options"])
    options = {"nested" => [{"value" => 1.25, "null" => nil, "off" => false}], "empty" => {}}
    equal(options, drafts.create(attributes.merge("game_id" => "unknown_32", "game_options" => options))["game_options"])
  end

  def test_mutable_results_never_change_inputs_or_later_reads
    drafts = store
    input = attributes
    first = drafts.create(input)
    original = store.fetch(first["id"])
    first["owner"].replace("intruz")
    first["game_options"]["custom"] << "zmiana"
    equal(attributes, input)
    equal(original, drafts.fetch(original["id"]))
    second = drafts.create(attributes)
    equal("tester", second["owner"])
    all = drafts.list
    all.first["game_options"].clear
    all.first["owner"].replace("inne")
    all.clear
    fetched = drafts.fetch(original["id"])
    fetched["name"].replace("inne")
    equal([original, second], drafts.list)
    changes = {"game_options" => {"nested" => ["abc"]}}
    updated = drafts.update(original["id"], changes, expected_revision: 1)
    expected = drafts.fetch(original["id"])
    updated["game_options"]["nested"].first.replace("zmiana")
    equal({"game_options" => {"nested" => ["abc"]}}, changes)
    changes["game_options"].clear
    equal(expected, store.fetch(original["id"]))
  end

  def test_corrupt_storage_is_never_repaired_or_overwritten
    drafts = store
    first = drafts.create(attributes)
    second = drafts.create(attributes.merge("name" => "Drugi"))
    healthy = JSON.parse(File.binread(data_file))
    # Wersja 2 jest teraz obsługiwana; 3 nadal musi blokować wszystkie operacje.
    variants = ["{", "", "null", "[]", "\xff".b,
      JSON.generate(healthy.merge("schema_version" => 3)),
      JSON.generate(healthy.merge("schema_version" => 1.0)), JSON.generate(healthy.merge("owner" => "obcy")),
      JSON.generate(healthy.reject { |key, _| key == "owner" }), JSON.generate(healthy.merge("drafts" => {})),
      JSON.generate(healthy.merge("drafts" => [nil])), JSON.generate(healthy.merge("extra" => true)),
      JSON.generate(healthy.merge("drafts" => [first, first]))]
    {"id" => [nil, "złe"], "owner" => ["obcy", "Tester"], "revision" => [0, "1", 1.0],
      "created_at" => [-1, nil, 1.0], "updated_at" => [-1, nil, 1.0], "status" => ["published", nil],
      "name" => [""], "game_id" => ["CHESS"], "game_options" => [[]], "format" => ["swiss"],
      "rematch" => [1], "participants" => [nil, ["A", "a"], [" A"], Array.new(257) { |i| "Gracz #{i}" }],
      "windows" => [nil, [details["windows"].first] * 2, Array.new(367, {})],
      "players_per_match" => [1, 9, 2.0, "2"], "pairing" => ["swiss", false]}.each do |field, values|
      values.each do |value|
        variants << JSON.generate(healthy.merge("drafts" => [first, second.merge(field => value)]))
      end
    end
    variants << JSON.generate(healthy.merge("drafts" => [first, second.merge("updated_at" => second["created_at"] - 1)]))
    second.keys.each do |key|
      # Historical schema 2 with manual groups predates this optional field.
      next if key == 'group_advancement'
      variants << JSON.generate(healthy.merge("drafts" => [first, second.reject { |field, _| field == key }]))
    end
    variants << JSON.generate(healthy.merge("drafts" => [first, second.merge("schedule" => "nie teraz")]))
    variants.each do |payload|
      File.binwrite(data_file, payload)
      stamp = File.mtime(data_file)
      [-> { drafts.list }, -> { drafts.fetch(first["id"]) }, -> { drafts.create(attributes) },
        -> { drafts.update(first["id"], {"name" => "Zmiana"}, expected_revision: 1) },
        -> { drafts.delete(first["id"], expected_revision: 1) }].each do |operation|
        raises(GameRoomTournaments::Drafts::Corrupt, &operation)
        equal(payload.b, File.binread(data_file))
        equal(stamp, File.mtime(data_file))
      end
    end
  end

  def test_stable_lock_serializes_instances_without_lost_writes
    drafts = store
    record = drafts.create(attributes)
    lock_path = "#{data_file}.lock"
    assert(File.file?(lock_path), "Brak osobnego stałego pliku blokady")
    File.open(lock_path, "r+b") do |lock|
      lock.flock(File::LOCK_EX)
      started = Queue.new
      worker = Thread.new { started << true; store.create(attributes.merge("name" => "Po blokadzie")) }
      begin
        started.pop
        equal(nil, worker.join(0.1))
        equal([record], JSON.parse(File.binread(data_file))["drafts"])
      ensure
        lock.flock(File::LOCK_UN)
        assert(worker.join(10), "Nie zwolniono blokady szkiców")
      end
      worker.value
    end
    threads = 6.times.map do |index|
      Thread.new do
        instance = store
        10.times { |number| instance.create(attributes.merge("name" => "#{index}:#{number}")) }
      end
    end
    threads.each { |thread| assert(thread.join(20), "Zablokowany zapis"); thread.value }
    equal(62, store.list.length)
    equal(62, drafts.list.map { |item| item["id"] }.uniq.length)
    outcomes = Queue.new
    racers = 6.times.map do
      Thread.new do
        begin
          store.update(record["id"], {"name" => "Jedna zmiana"}, expected_revision: 1)
          outcomes << :saved
        rescue GameRoomTournaments::Drafts::Conflict
          outcomes << :conflict
        end
      end
    end
    racers.each { |thread| assert(thread.join(20)); thread.value }
    results = 6.times.map { outcomes.pop }
    equal(1, results.count(:saved))
    equal(5, results.count(:conflict))
    equal(2, drafts.fetch(record["id"])["revision"])
    assert(File.file?(lock_path))
  end

  def test_atomic_replacement_flushes_and_preserves_the_previous_file_on_failure
    drafts = store
    record = drafts.create(attributes)
    bytes = File.binread(data_file)
    probe = {path: data_file, events: [], before_rename: ->(temporary) {
      equal(bytes, File.binread(data_file))
      equal(File.dirname(data_file), File.dirname(temporary))
      equal(2, JSON.parse(File.binread(temporary))["drafts"].first["revision"])
    }}
    Thread.current[:tournament_draft_probe] = probe
    changed = drafts.update(record["id"], {"name" => "Atomowo"}, expected_revision: 1)
    equal([:flush, :fsync, :rename], probe[:events])
    equal(changed, store.fetch(record["id"]))
    bytes = File.binread(data_file)
    probe.delete(:before_rename)
    {write: Errno::ENOSPC, fsync: IOError, rename: Errno::EACCES}.each do |stage, error|
      probe[:fail] = stage
      [-> { drafts.create(attributes) }, -> { drafts.update(record["id"], {"name" => "Utracone"}, expected_revision: 2) },
        -> { drafts.delete(record["id"], expected_revision: 2) }].each do |operation|
        raises(error, &operation)
        equal(bytes, File.binread(data_file))
        equal([], Dir.glob("*.tmp-*", base: @directory))
        equal([changed], store.list)
      end
    end
    probe[:fail] = nil
    equal(true, drafts.delete(record["id"], expected_revision: 2))
    equal([], drafts.list)
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_storage_size_is_bounded_for_reads_and_writes
    drafts = store
    record = drafts.create(attributes)
    healthy = File.binread(data_file)
    maximum = 4_194_304
    oversized = healthy + " " * (maximum + 1 - healthy.bytesize)
    File.binwrite(data_file, oversized)
    probe = {path: data_file, reads: [], events: []}
    Thread.current[:tournament_draft_probe] = probe
    raises(GameRoomTournaments::Drafts::Corrupt) { drafts.list }
    equal([maximum + 1], probe[:reads])
    Thread.current[:tournament_draft_probe] = nil
    raises(GameRoomTournaments::Drafts::Corrupt) { drafts.create(attributes) }
    equal(oversized.b, File.binread(data_file))
    File.binwrite(data_file, healthy + " " * (maximum - healthy.bytesize))
    equal([record], drafts.list)
    File.binwrite(data_file, healthy)
    error = raises(GameRoomTournaments::Drafts::Invalid) { drafts.create(attributes.merge("game_id" => "a" * maximum)) }
    equal(:invalid_options, error.code)
    equal(healthy, File.binread(data_file))
    equal([], Dir.glob("*.tmp-*", base: @directory))
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_owner_is_normalized_isolated_and_never_used_as_a_path
    first = store(" Tester ").create(attributes)
    equal("tester", first["owner"])
    equal([first], store("TESTER").list)
    equal([], store("Other").list)
    other = store("Other").create(attributes)
    equal("other", other["owner"])
    equal([first], store.list)
    File.binwrite(data_file("other"), File.binread(data_file))
    raises(GameRoomTournaments::Drafts::Corrupt) { store("Other").list }
    tricky = "../Outside\\Account"
    record = store(tricky).create(attributes)
    equal(tricky.downcase, record["owner"])
    assert(File.file?(data_file(tricky.downcase)))
    assert(Dir.children(@directory).all? { |name| name.match?(/\Atournament-drafts-[0-9a-f]{64}\.json(?:\.lock)?\z/) })
    before = Dir.children(@directory).sort
    [nil, 5, "", "  ", "a\nb", "a\u0000b", "\xff".force_encoding("UTF-8")].each do |owner|
      raises(ArgumentError) { store(owner).list }
    end
    equal(before, Dir.children(@directory).sort)
    [nil, 5, false, "", "a\0b", "\xff".force_encoding("UTF-8"), "\xff".b, "abc".encode("UTF-16LE")].each do |path|
      raises(ArgumentError) { GameRoomTournaments::Drafts.new(Program.new(path), owner: "Tester").list }
    end
    equal(before, Dir.children(@directory).sort)
    missing = File.join(@directory, "missing")
    raises(SystemCallError) { GameRoomTournaments::Drafts.new(Program.new(missing), owner: "Tester").list }
    assert(!File.exist?(missing))
  end

  def test_native_portable_data_path_survives_a_cwd_change
    Open3.popen2e(RbConfig.ruby, File.expand_path(__FILE__), "--portable-path", @directory) do |input, output, waiter|
      input.close
      begin
        assert(waiter.join(20), "Proces natywnego data_path nie zakończył pracy")
        message = output.read
        assert(waiter.value.success?, message)
        @assertions += JSON.parse(message).fetch("assertions")
      ensure
        if waiter.alive?
          Process.kill("KILL", waiter.pid)
          waiter.join
        end
      end
    end
  end

  def verify_native_portable_data_path(directory)
    @assertions = 0
    require_relative "../support/host_source"
    # Tylko natywny moduł ścieżek, bez pozostałych zależności bootstrapa hosta.
    bootstrap = EltenTestHost.file("src/bootstrap.rb")
    lines = File.readlines(bootstrap)
    first = lines.index { |line| line.strip == "module EltenPath" }
    assert(first, "Brak natywnego modułu EltenPath")
    Object.class_eval(lines[first..].join, bootstrap, first + 1)
    require EltenTestHost.file("src/eapi/structs.rb")
    Object.include(EltenAPI)
    require EltenTestHost.file("src/eapi/program.rb")

    Dir.chdir(directory) do
      # Ten sam względny katalog co w portable; wszystkie dane w scratch.
      Dirs.eltendata = "./eltendata"
      Dirs.appsdata = EltenPath.join(Dirs.eltendata, "apps")
      Dirs.apps = EltenPath.join(Dirs.appsdata, "src")
      runtime = Programs::Runtime.allocate
      runtime.instance_variable_set(:@entry_id, "tournament-drafts-test.eltenapp")
      ::Program.instance_variable_set(:@app_runtime, runtime)
      program = ::Program.allocate
      root = program.data_path
      equal("./eltendata/apps/data/tournament-drafts-test", root)
      path = File.expand_path(File.join(root, "tournament-drafts-#{Digest::SHA256.hexdigest('tester')}.json"))
      drafts = GameRoomTournaments::Drafts.new(program, owner: "Tester")
      first_record = drafts.create(attributes)
      equal([first_record], drafts.list)
      other = File.join(directory, "other-cwd")
      FileUtils.mkdir_p(File.join(other, root))
      Dir.chdir(other) do
        equal(first_record, drafts.fetch(first_record["id"]))
        changed = drafts.update(first_record["id"], {"name" => "Po zmianie cwd"}, expected_revision: 1)
        equal(2, changed["revision"])
        equal([changed], drafts.list)
        equal([changed], JSON.parse(File.binread(path)).fetch("drafts"))
        equal([], Dir.children(root))
        equal(true, drafts.delete(first_record["id"], expected_revision: 2))
        equal([], drafts.list)
        equal([], JSON.parse(File.binread(path)).fetch("drafts"))
        equal([], Dir.children(root))
      end
    end
    puts JSON.generate("assertions" => @assertions)
  end

  def test_every_record_is_revalidated_at_the_write_boundary
    first = store.create(attributes)
    store.create(attributes.merge("name" => "Drugi"))
    bytes = File.binread(data_file)
    # Symulacja uszkodzenia dokumentu w pamięci już po prawidłowym odczycie.
    klass = Class.new(GameRoomTournaments::Drafts) do
      private
      def read
        super.tap { |document| document["drafts"].last["name"] = "" }
      end
    end
    drafts = klass.new(@program, owner: "Tester")
    [-> { drafts.create(attributes) }, -> { drafts.update(first["id"], {}, expected_revision: 1) },
      -> { drafts.delete(first["id"], expected_revision: 1) }].each do |operation|
      raises(GameRoomTournaments::Drafts::Corrupt, &operation)
      equal(bytes, File.binread(data_file))
    end
  end

  def test_disk_and_lock_errors_are_not_an_empty_list
    drafts = store
    record = drafts.create(attributes)
    bytes = File.binread(data_file)
    [Errno::EACCES, Errno::EIO].each do |error|
      Thread.current[:tournament_draft_probe] = {path: data_file, events: [], read_error: error}
      raises(error) { drafts.list }
      raises(error) { drafts.fetch(record["id"]) }
      raises(error) { drafts.create(attributes) }
      raises(error) { drafts.update(record["id"], {}, expected_revision: 1) }
      raises(error) { drafts.delete(record["id"], expected_revision: 1) }
      Thread.current[:tournament_draft_probe] = nil
      equal(bytes, File.binread(data_file))
    end
    Thread.current[:tournament_draft_probe] = {path: data_file, events: [], fail: :lock}
    raises(IOError) { drafts.list }
    raises(IOError) { drafts.create(attributes) }
    equal(bytes, File.binread(data_file))
    Thread.current[:tournament_draft_probe] = nil
    equal([record], drafts.list)
  ensure
    Thread.current[:tournament_draft_probe] = nil
  end

  def test_separate_processes_share_the_stable_lock
    children = []
    begin
      3.times do
        children << Open3.popen2e(RbConfig.ruby, File.expand_path(__FILE__), "--writer", @directory)
      end
      Timeout.timeout(20) { children.each { |_, output, _| equal("READY\n", output.gets&.tr("\r", "")) } }
      store.list
      File.open("#{data_file}.lock", "r+b") do |lock|
        lock.flock(File::LOCK_EX)
        begin
          children.each { |input, _, _| input.puts("START"); input.flush }
          children.each { |_, _, waiter| equal(nil, waiter.join(0.1)) }
          assert(!File.exist?(data_file))
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
      children.each do |input, output, waiter|
        input.close
        assert(waiter.join(20), "Proces szkiców nie zakończył pracy")
        message = output.read
        assert(waiter.value.success?, message)
      end
      equal(30, store.list.length)
      equal(30, store.list.map { |record| record["id"] }.uniq.length)
    ensure
      children.each do |input, output, waiter|
        input.close unless input.closed?
        if waiter.alive?
          Process.kill("KILL", waiter.pid)
          waiter.join
        end
        output.close unless output.closed?
      end
    end
  end

  def run
    @assertions = 0
    failures = []
    cases = methods.grep(/^test_/).sort
    cases = cases.select { |name| name.to_s.include?(ARGV.fetch(1)) } if ARGV.first == "--only"
    raise "Nie wybrano testów" if cases.empty?
    cases.each do |name|
      Dir.mktmpdir("tournament-drafts-test-", ENV.fetch("TMPDIR")) do |directory|
        @directory = directory
        @program = Program.new(directory)
        begin
          send(name)
          puts "PASS #{name}"
        rescue StandardError => error
          failures << name
          warn "FAIL #{name}: #{error.class}: #{error.message}\n#{error.backtrace.first(4).join("\n")}"
        end
      end
    end
    puts "Przypadki: #{cases.length}; asercje: #{@assertions}; błędy: #{failures.length}"
    failures.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  if ["--writer", "--portable-path"].include?(ARGV.first)
    directory = File.realpath(ARGV.fetch(1))
    root = File.realpath(ENV.fetch("TMPDIR"))
    unless File.dirname(directory) == root && File.basename(directory).start_with?("tournament-drafts-test-")
      abort "Proces testowy wymaga własnego katalogu pod TMPDIR"
    end
    if ARGV.first == "--portable-path"
      TournamentDraftsTest.new.verify_native_portable_data_path(directory)
    else
      $stdout.sync = true
      puts "READY"
      abort "Brak sygnału startu" unless $stdin.gets&.strip == "START"
      drafts = GameRoomTournaments::Drafts.new(TournamentDraftsTest::Program.new(directory), owner: "Tester")
      10.times { drafts.create(TournamentDraftsTest.new.attributes) }
    end
  else
    exit(TournamentDraftsTest.new.run ? 0 : 1)
  end
end
