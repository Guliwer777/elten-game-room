# encoding: UTF-8
require_relative '../support/temporary_directory'
require "tmpdir"
require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"

source = File.expand_path("../../lib/tournaments/local_test_tables.rb", __dir__)
require source if File.file?(source)

# Iniekcje awarii są ograniczone do plików sandboxa i bieżącego wątku testu.
module TournamentLocalTablesProbePaths
  def self.logical(path)
    path.delete_prefix('\\\\?\\').tr('\\', '/')
  end
end

module TournamentLocalTablesFileProbe
  def write(payload)
    probe = Thread.current[:local_tables_probe]
    if probe && TournamentLocalTablesProbePaths.logical(path).start_with?(probe[:path] + ".tmp-")
      probe[:events] << :write
      return super(payload.byteslice(0, 8)) if probe[:fail] == :short_write
      if probe[:fail] == :write
        super(payload.byteslice(0, 8))
        raise Errno::ENOSPC, "Awaria testowa"
      end
    end
    super
  end

  def flush
    probe = Thread.current[:local_tables_probe]
    if probe && TournamentLocalTablesProbePaths.logical(path).start_with?(probe[:path] + ".tmp-")
      probe[:events] << :flush
      raise IOError, "Awaria testowa" if probe[:fail] == :flush
    end
    super
  end

  def fsync
    probe = Thread.current[:local_tables_probe]
    if probe && TournamentLocalTablesProbePaths.logical(path).start_with?(probe[:path] + ".tmp-")
      probe[:events] << :fsync
      raise IOError, "Awaria testowa" if probe[:fail] == :fsync
    end
    super
  end

  def flock(operation)
    probe = Thread.current[:local_tables_probe]
    if probe && TournamentLocalTablesProbePaths.logical(path) == probe[:path] + ".lock" && operation == File::LOCK_EX && probe[:fail] == :lock
      return false
    end
    super
  end
end

module TournamentLocalTablesRenameProbe
  def rename(source, destination)
    probe = Thread.current[:local_tables_probe]
    matching = probe && TournamentLocalTablesProbePaths.logical(destination) == probe[:path]
    if matching
      probe[:events] << :rename
      raise Errno::EACCES, "Awaria testowa" if probe[:fail] == :rename
    end
    result = super
    raise IOError, "Utrata potwierdzenia" if matching && probe[:fail] == :rename_after

    result
  end
end
File.prepend(TournamentLocalTablesFileProbe)
File.singleton_class.prepend(TournamentLocalTablesRenameProbe)

module TournamentLocalTablesJsonProbe
  def parse(source, **options)
    options = options.merge(allow_duplicate_key: true, object_class: Hash) if Thread.current[:local_tables_legacy_json]
    super(source, **options)
  end
end
JSON.singleton_class.prepend(TournamentLocalTablesJsonProbe)

class TournamentLocalTestTablesTest
  ANNOUNCEMENTS = "tournament_announcements".freeze
  REGISTRATIONS = "tournament_registrations".freeze

  def assert(value, message = "Niespełniona asercja")
    @assertions += 1
    raise message unless value
  end

  def equal(expected, actual)
    assert(expected == actual, "Oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def store(user: proc { @actor }, directory: @directory, clock: proc { Time.at(1_800_000_000) })
    assert(defined?(GameRoomTournaments::LocalTestTables), "Brak jawnego lokalnego adaptera testowego")
    GameRoomTournaments::LocalTestTables.new(directory: directory, user: user, clock: clock)
  end

  def data_file
    File.join(@directory, "tournament-local-test-tables.json")
  end

  def test_shared_durable_append_only_tables_and_read_only_listing
    draft = File.join(@directory, "tournament-drafts-fixture.json")
    outbox = File.join(@directory, "tournament-outbox-fixture.json")
    [draft, outbox].each { |path| File.binwrite(path, "nie dotykaj") }
    first = store
    assert(first.available?)
    assert(GameRoomTournaments::LocalTestTables::TABLES.all?(&:frozen?))
    assert(GameRoomTournaments::LocalTestTables::METADATA.all?(&:frozen?))
    equal(true, first.local_test?)
    equal("local_test:#{data_file}", first.backend_identity)
    equal([], first.fetch(ANNOUNCEMENTS).select)
    assert(!File.exist?(data_file), "Sam odczyt nie tworzy JSON")
    payload = {"title" => "Zażółć gęślą", "settings" => {"players" => ["Żaneta", nil, true, 3, 1.25]}}
    original = JSON.generate(payload)
    row = first.fetch(ANNOUNCEMENTS).insert(payload)
    equal(original, JSON.generate(payload))
    equal(1, row["__id"])
    equal("Testowa Alicja", row["__insertion_user"])
    equal(1_800_000_000, row["__insertion_time"])
    @actor = "Testowy Bartek"
    reopened = store
    equal([row], reopened.fetch(ANNOUNCEMENTS).select)
    payload["settings"]["players"] << "zmiana argumentu"
    row["settings"]["players"] << "zmiana wyniku"
    fresh = reopened.fetch(ANNOUNCEMENTS).select.first
    equal(JSON.parse(original)["settings"], fresh["settings"])
    fresh["settings"]["players"].clear
    equal(JSON.parse(original)["settings"], first.fetch(ANNOUNCEMENTS).select.first["settings"])
    equal(2, first.fetch(ANNOUNCEMENTS).insert({"title" => "Drugi"})["__id"])
    registration = reopened.fetch(REGISTRATIONS).insert({"tournament_id" => 1})
    equal(1, registration["__id"])
    equal("Testowy Bartek", registration["__insertion_user"])
    equal("Testowa Alicja", first.fetch(ANNOUNCEMENTS).select.first["__insertion_user"])
    before = File.binread(data_file)
    before_time = File.mtime(data_file)
    store.fetch(ANNOUNCEMENTS).select
    equal(before, File.binread(data_file))
    equal(before_time, File.mtime(data_file))
    [draft, outbox].each { |path| equal("nie dotykaj", File.binread(path)) }
    table = first.fetch(ANNOUNCEMENTS)
    [:update, :delete, :upsert, :insert_many].each { |method| assert(!table.respond_to?(method)) }
    assert(!first.respond_to?(:check_access))
  end

  def error_code(code)
    @assertions += 1
    begin
      yield
    rescue GameRoomTournaments::LocalTestTables::Error => error
      equal(code, error.code)
      return error
    end
    raise "Oczekiwano błędu #{code}"
  end

  def test_actor_opt_in_is_checked_for_cached_handles
    provider = store
    table = provider.fetch(ANNOUNCEMENTS)
    assert(provider.available?)
    equal(:available, provider.access_state)
    equal(false, provider.stamp_required?)
    equal(nil, provider.last_error)
    [nil, "", "  ", 17, :test, "zły\naktor", "x\u2028y", " x", "x ", "x" * 129, "\xff".b].each do |invalid|
      @actor = invalid
      equal(false, provider.available?)
      equal(:unavailable, provider.access_state)
      error_code(:invalid_test_user) { table.select }
      error_code(:invalid_test_user) { table.insert({}) }
    end
    @actor = "Testowy Bartek"
    assert(provider.available?)
    equal("Testowy Bartek", table.insert({})["__insertion_user"])
    calls = 0
    actor = +"Testowa Alicja"
    changing = store(user: proc { calls += 1; actor }, clock: proc { actor.replace("Testowy Bartek"); Time.at(50) })
    calls = 0
    equal("Testowa Alicja", changing.fetch(REGISTRATIONS).insert({})["__insertion_user"])
    equal(1, calls)
  end

  def test_actor_limits_match_publication_without_persisting_rejected_names
    provider = store
    table = provider.fetch(ANNOUNCEMENTS)
    ['x', 'x' * 64, '😀' * 64].each do |actor|
      @actor = actor
      assert(provider.available?)
      equal(actor, table.insert({})['__insertion_user'])
    end
    before = File.binread(data_file)
    ['x' * 65, '😀' * 65, "\u00a0A", "A\u3000"].each do |actor|
      @actor = actor
      equal(false, provider.available?)
      error_code(:invalid_test_user) { table.insert({}) }
      equal(before, File.binread(data_file))
    end
    @actor = 'Testowa Alicja'
    damaged = JSON.parse(before)
    damaged['tables'][ANNOUNCEMENTS]['rows'].first['__insertion_user'] = 'x' * 65
    payload = JSON.generate(damaged).b
    File.binwrite(data_file, payload)
    error_code(:corrupt_store) { store }
    equal(payload, File.binread(data_file))
  end

  def test_allowlist_and_reserved_metadata
    provider = store
    [nil, "", :tournament_announcements, "game_room_users", "../drafts"].each do |name|
      error_code(:invalid_table) { provider.fetch(name) }
    end
    table = provider.fetch(ANNOUNCEMENTS)
    ["__id", "__insertion_user", "__insertion_time", "__unknown"].each do |key|
      error_code(:invalid_values) { table.insert({key => "podszycie"}) }
    end
    assert(!File.exist?(data_file))
  end

  def test_json_type_size_and_clock_validation
    table = store.fetch(ANNOUNCEMENTS)
    cycle = []; cycle << cycle
    deep = nil; 20.times { deep = [deep] }
    [nil, [], "tekst", {x: 1}, {"x" => {y: 1}}, {"x" => Object.new},
      {"x" => Float::NAN}, {"x" => Float::INFINITY}, {"x" => "\xff".b},
      {"x" => 2**100}, {"x" => cycle}, {"x" => deep}, {"x" => [nil] * 9000}].each do |values|
      error_code(:invalid_values) { table.insert(values) }
    end
    error_code(:row_too_large) { table.insert({"x" => "ż" * 65_536}) }
    [nil, "123", -1, 1.5, Object.new].each do |clock|
      error_code(:invalid_clock) { store(clock: proc { clock }).fetch(ANNOUNCEMENTS).insert({}) }
    end
    assert(!File.exist?(data_file))
    row = store(clock: proc { Time.new(2026, 1, 1, 12, 0, 0, "+02:00") }).fetch(ANNOUNCEMENTS).insert({})
    equal(Time.utc(2026, 1, 1, 10).to_i, row["__insertion_time"])
    equal(5, store(clock: proc { 5 }).fetch(ANNOUNCEMENTS).insert({})["__insertion_time"])
  end

  def test_select_filters_order_projection_and_pagination
    table = store.fetch(ANNOUNCEMENTS)
    [["A", 3], ["B", 2], ["A", 2], ["A", 1]].each do |group, score|
      table.insert({"group" => group, "score" => score, "optional" => nil})
    end
    options = {where: {"group" => "A", "score" => {"gte" => 2, "lte" => 3, "in" => [2, 3]}},
      order: [["score", "desc"], ["__id", "asc"]], offset: 1, limit: 1,
      columns: ["group", "__id", "__insertion_user", "__insertion_time"]}
    original = Marshal.dump(options)
    equal([{"group" => "A", "__id" => 3, "__insertion_user" => "Testowa Alicja", "__insertion_time" => 1_800_000_000}], table.select(**options))
    equal(original, Marshal.dump(options))
    equal([4, 2, 3, 1], table.select(order: [["score", "asc"]]).map { |row| row["__id"] })
    equal([1, 2, 3, 4], table.select(where: {"optional" => nil}).map { |row| row["__id"] })
    equal([], table.select(where: {"missing" => nil}))
    equal([], table.select(where: {"score" => {"in" => []}}))
    equal([], table.select(limit: 0))
    equal([], table.select(offset: 100))
    equal([{}, {}, {}, {}], table.select(columns: []))
    equal([{"score" => 3}], table.select(columns: ["score"], limit: 1))
    equal([1, 2, 3, 4], table.select(where: {"group" => {"gte" => "A", "lte" => "Z"}}).map { |row| row["__id"] })
  end

  def test_select_rejects_unsupported_operators_and_types_even_when_empty
    table = store.fetch(ANNOUNCEMENTS)
    invalid = [{where: []}, {where: {score: 1}}, {where: {"score" => {"eq" => 1}}},
      {where: {"score" => {gte: 1}}}, {where: {"score" => {}}},
      {where: {"score" => {"in" => 2}}}, {where: {"score" => {"in" => [[1]]}}},
      {where: {"score" => {"gte" => nil}}}, {where: {"score" => {"lte" => true}}},
      {where: {"score" => [1]}}, {where: {"score" => Float::INFINITY}},
      {order: "score"}, {order: [["score", "ASC"]]}, {order: [["score"]]},
      {order: [[:score, "asc"]]}, {columns: "score"}, {columns: [:score]},
      {columns: ["__unknown"]}, {limit: "1"}, {limit: -1}, {offset: 1.5}, {offset: -1}]
    invalid.each { |options| error_code(:invalid_query) { table.select(**options) } }
    table.insert({"score" => "tekst"})
    error_code(:invalid_query) { table.select(where: {"score" => {"gte" => 1}}) }
    table.insert({"score" => 2})
    error_code(:invalid_query) { table.select(order: [["score", "asc"]]) }
    error_code(:invalid_query) { table.select(order: [["missing", "asc"]]) }
  end

  def test_corruption_and_incompatible_schema_are_never_reset
    provider = store
    provider.fetch(ANNOUNCEMENTS).insert({"title" => "Oryginał"})
    good = File.binread(data_file)
    invalid_json = ["", "{", "null", "[]", "{\"schema_version\":1,\"schema_version\":1,\"tables\":{}}"]
    invalid_json.each do |payload|
      File.binwrite(data_file, payload)
      error_code(:corrupt_store) { store }
      error_code(:corrupt_store) { provider.fetch(ANNOUNCEMENTS).select }
      error_code(:corrupt_store) { provider.fetch(ANNOUNCEMENTS).insert({}) }
      equal(payload.b, File.binread(data_file))
    end
    document = JSON.parse(good)
    document["schema_version"] = 99
    payload = JSON.generate(document)
    File.binwrite(data_file, payload)
    error_code(:incompatible_schema) { store }
    equal(payload.b, File.binread(data_file))
    File.binwrite(data_file, good)
    equal("Oryginał", store.fetch(ANNOUNCEMENTS).select.first["title"])
  end

  def test_every_persisted_row_and_all_envelope_metadata_are_validated
    provider = store
    provider.fetch(ANNOUNCEMENTS).insert({"title" => "Dobry"})
    provider.fetch(REGISTRATIONS).insert({"tournament_id" => 1})
    good = File.binread(data_file)
    changes = [proc { |d| d["extra"] = 1 }, proc { |d| d["mode"] = "server" },
      proc { |d| d["schema_version"] = 1.0 }, proc { |d| d["tables"].delete(REGISTRATIONS) },
      proc { |d| d["tables"]["other"] = [] }, proc { |d| d["tables"][REGISTRATIONS]["last_id"] = 5 },
      proc { |d| d["tables"][REGISTRATIONS]["extra"] = 1 },
      proc { |d| d["tables"][REGISTRATIONS]["rows"] << d["tables"][REGISTRATIONS]["rows"].first.dup }]
    [0, -1, "1", 1.0, nil].each do |id|
      changes << proc { |d| d["tables"][REGISTRATIONS]["rows"].first["__id"] = id }
    end
    [nil, "", "\nfałszywy"].each do |actor|
      changes << proc { |d| d["tables"][REGISTRATIONS]["rows"].first["__insertion_user"] = actor }
    end
    [nil, -1, "123", 1.0].each do |time|
      changes << proc { |d| d["tables"][REGISTRATIONS]["rows"].first["__insertion_time"] = time }
    end
    changes << proc { |d| d["tables"][REGISTRATIONS]["rows"].first["__extra"] = true }
    changes << proc { |d| d["tables"][REGISTRATIONS]["rows"].first["bad"] = 2**100 }
    changes.each do |change|
      document = JSON.parse(good)
      change.call(document)
      payload = JSON.generate(document)
      File.binwrite(data_file, payload)
      error_code(:corrupt_store) { store }
      error_code(:corrupt_store) { provider.fetch(ANNOUNCEMENTS).select }
      equal(payload.b, File.binread(data_file))
    end
  end

  def test_store_row_and_byte_limits_do_not_overwrite_data
    klass = GameRoomTournaments::LocalTestTables
    table = store.fetch(ANNOUNCEMENTS)
    template = table.insert({})
    document = JSON.parse(File.binread(data_file))
    state = document["tables"][ANNOUNCEMENTS]
    state["rows"] = (1..klass::MAX_ROWS_PER_TABLE).map { |id| template.merge("__id" => id) }
    state["last_id"] = klass::MAX_ROWS_PER_TABLE
    File.binwrite(data_file, JSON.generate(document))
    full = File.binread(data_file)
    equal(klass::MAX_ROWS_PER_TABLE, table.select.length)
    error_code(:store_limit) { table.insert({}) }
    equal(full, File.binread(data_file))
    state["rows"] << template.merge("__id" => klass::MAX_ROWS_PER_TABLE + 1)
    state["last_id"] += 1
    File.binwrite(data_file, JSON.generate(document))
    error_code(:store_limit) { store }
    File.binwrite(data_file, " " * (klass::MAX_FILE_BYTES + 1))
    error_code(:store_limit) { store }
    equal(klass::MAX_FILE_BYTES + 1, File.size(data_file))
  end

  def with_probe(fail = nil)
    probe = {path: data_file, fail: fail, events: []}
    Thread.current[:local_tables_probe] = probe
    yield(probe)
  ensure
    Thread.current[:local_tables_probe] = nil
  end

  def test_atomic_write_failures_preserve_old_database_and_other_temporary_files
    provider = store
    table = provider.fetch(ANNOUNCEMENTS)
    table.insert({"title" => "Przed"})
    before = File.binread(data_file)
    foreign = data_file + ".tmp-other"
    File.binwrite(foreign, "cudzy plik")
    [:short_write, :write, :flush, :fsync, :rename, :lock].each do |failure|
      with_probe(failure) { error_code(:store_io_error) { table.insert({"title" => "Po"}) } }
      equal(:store_io_error, provider.last_error.code)
      equal(before, File.binread(data_file))
      equal([File.basename(foreign)], Dir.glob("*.tmp-*", base: @directory))
      equal("cudzy plik", File.binread(foreign))
    end
    with_probe do |probe|
      equal(2, table.insert({"title" => "Po"})["__id"])
      equal([:write, :flush, :fsync, :rename], probe[:events])
    end
    equal(nil, provider.last_error)
    assert(File.file?(data_file + ".lock"))
  end

  def test_uncertain_rename_never_rolls_back_or_reuses_an_id
    table = store.fetch(ANNOUNCEMENTS)
    table.insert({"title" => "Pierwszy"})
    with_probe(:rename_after) { error_code(:store_io_error) { table.insert({"title" => "Drugi"}) } }
    equal([1, 2], table.select.map { |row| row["__id"] })
    equal(3, table.insert({"title" => "Trzeci"})["__id"])
    equal([], Dir.glob("*.tmp-*", base: @directory))
  end

  def workers(count, code)
    source = File.expand_path("../../lib/tournaments/local_test_tables.rb", __dir__)
    children = []
    Timeout.timeout(30) do
      count.times { |index| children << Open3.popen2e(RbConfig.ruby, "-r", source, "-e", code, @directory, "Test-#{index}") }
      yield(children)
    end
  ensure
    children.each do |input, output, waiter|
      input.close unless input.closed?
      output.close unless output.closed?
      Process.kill("KILL", waiter.pid) if waiter.alive?
      waiter.join
    end
  end

  def child_code(count)
    <<~RUBY
      $stdout.sync = true
      provider = GameRoomTournaments::LocalTestTables.new(directory: ARGV[0], user: proc { ARGV[1] })
      table = provider.fetch("tournament_announcements")
      puts "READY"
      STDIN.gets
      #{count}.times { |index| table.insert({"operation" => ARGV[1] + ":" + index.to_s}) }
      puts "DONE"
    RUBY
  end

  def test_two_processes_append_without_lost_rows_or_duplicate_ids
    workers(2, child_code(30)) do |children|
      children.each { |_input, output, _waiter| equal("READY\n", output.gets) }
      children.each { |input, _output, _waiter| input.puts("go"); input.flush }
      children.each do |_input, output, waiter|
        result = output.read
        assert(waiter.value.success?, result)
        equal("DONE\n", result)
      end
    end
    rows = store.fetch(ANNOUNCEMENTS).select
    equal((1..60).to_a, rows.map { |row| row["__id"] })
    equal(60, rows.map { |row| row["operation"] }.uniq.length)
    equal({"Test-0" => 30, "Test-1" => 30}, rows.group_by { |row| row["__insertion_user"] }.transform_values(&:length))
  end

  def test_separate_lock_file_blocks_other_process_insertion
    workers(1, child_code(1)) do |children|
      input, output, waiter = children.first
      equal("READY\n", output.gets)
      File.open(data_file + ".lock", File::RDWR | File::CREAT, 0o600) do |lock|
        assert(lock.flock(File::LOCK_EX))
        begin
          input.puts("go"); input.flush
          reader = Thread.new { output.gets }
          assert(!reader.join(0.2), "Inny proces ominął flock")
          assert(!File.exist?(data_file))
        ensure
          lock.flock(File::LOCK_UN)
        end
        equal("DONE\n", reader.value)
      end
      assert(waiter.value.success?)
    end
  end

  def test_relative_directory_is_resolved_once_and_new_directories_are_explicit
    original = Dir.pwd
    FileUtils.mkdir_p(File.join(@directory, "elsewhere"))
    provider = nil
    begin
      Dir.chdir(@directory)
      provider = store(directory: "./sandbox/new")
      identity = provider.backend_identity
      Dir.chdir(File.join(@directory, "elsewhere"))
      provider.fetch(ANNOUNCEMENTS).insert({"title" => "Przenośny"})
      equal(identity, provider.backend_identity)
      assert(File.file?(File.join(@directory, "sandbox/new/tournament-local-test-tables.json")))
      assert(!File.exist?(File.join(@directory, "elsewhere/sandbox")))
      equal(1, provider.fetch(ANNOUNCEMENTS).select.length)
    ensure
      Dir.chdir(original)
    end
  end

  def test_invalid_paths_and_callbacks_fail_with_codes
    [nil, "", "  ", 3, "x\0y", "x\ny", "\xff".b, "//invalid-host/share", "\\\\invalid-host\\share", "C:relative"].each do |directory|
      error_code(:invalid_directory) { store(directory: directory) }
    end
    occupied = File.join(@directory, "occupied")
    File.binwrite(occupied, "cudze dane")
    error_code(:invalid_directory) { store(directory: occupied) }
    equal("cudze dane", File.binread(occupied))
    error_code(:invalid_test_user) { store(user: nil) }
    error_code(:invalid_clock) { store(clock: nil) }
  end

  def test_existing_nonregular_database_or_lock_is_rejected
    Dir.mkdir(data_file)
    error_code(:unsafe_path) { store }
    Dir.rmdir(data_file)
    Dir.mkdir(data_file + ".lock")
    error_code(:unsafe_path) { store }
    assert(File.directory?(data_file + ".lock"))
  end

  def make_directory_link(target, link)
    File.symlink(target, link)
  rescue NotImplementedError, Errno::EACCES, Errno::EPERM
    raise unless File::ALT_SEPARATOR == "\\"

    output, status = Open3.capture2e("cmd.exe", "/d", "/c", "mklink", "/J", link.tr("/", "\\"), target.tr("/", "\\"))
    assert(status.success?, output)
  end

  def test_existing_directory_link_is_rejected_without_touching_target
    target = File.join(@directory, "target")
    link = File.join(@directory, "link")
    Dir.mkdir(target)
    make_directory_link(target, link)
    begin
      assert(File.lstat(link).symlink?, "Ruby musi rozpoznawać dowiązanie katalogu")
      error_code(:unsafe_path) { store(directory: link) }
      error_code(:unsafe_path) { store(directory: File.join(link, "new")) }
      equal([], Dir.children(target))
    ensure
      # Junction na Windows usuwamy bez przechodzenia do celu.
      File::ALT_SEPARATOR == "\\" ? Dir.rmdir(link) : File.unlink(link)
    end
  end

  def test_invalid_key_encoding_and_all_errors_have_ui_codes
    provider = store
    table = provider.fetch(ANNOUNCEMENTS)
    error_code(:invalid_values) { table.insert({"key".encode("UTF-16LE") => 1}) }
    equal(:invalid_values, provider.last_error.code)
    error_code(:invalid_query) { table.select(where: {"__id" => {"gte" => 1, "lte" => "z"}}) }
    equal(:invalid_query, provider.last_error.code)
    error_code(:invalid_table) { provider.fetch("other") }
    equal(:invalid_table, provider.last_error.code)
    @actor = nil
    error_code(:invalid_test_user) { table.insert({}) }
    equal(:invalid_test_user, provider.last_error.code)
    @actor = "Testowa Alicja"
    table.insert({})
    equal(nil, provider.last_error)
  end

  def test_store_byte_limit_is_enforced_on_insert_before_rename
    klass = GameRoomTournaments::LocalTestTables
    table = store.fetch(ANNOUNCEMENTS)
    template = table.insert({"text" => "x" * 64_000})
    document = JSON.parse(File.binread(data_file))
    count = (klass::MAX_FILE_BYTES - 1024) / (JSON.generate(template).bytesize + 20)
    state = document["tables"][ANNOUNCEMENTS]
    state["rows"] = (1..count).map { |id| template.merge("__id" => id) }
    state["last_id"] = count
    payload = JSON.generate(document).b
    assert(payload.bytesize <= klass::MAX_FILE_BYTES)
    assert(payload.bytesize + JSON.generate(template).bytesize > klass::MAX_FILE_BYTES)
    File.binwrite(data_file, payload)
    error_code(:store_limit) { table.insert({"text" => "x" * 64_000}) }
    equal(payload, File.binread(data_file))
    equal([], Dir.glob("*.tmp-*", base: @directory))
  end

  def test_duplicate_json_keys_in_valid_envelope_or_nested_payload_are_rejected
    store.fetch(ANNOUNCEMENTS).insert({"settings" => {"key" => 1}})
    good = File.binread(data_file)
    [good.sub('"schema_version":1', '"schema_version":1,"schema_version":1'),
      good.sub('"key":1', '"key":1,"key":2')].each do |payload|
      File.binwrite(data_file, payload)
      error_code(:corrupt_store) { store }
      equal(payload, File.binread(data_file))
    end
  end

  def test_existing_file_hardlinks_are_rejected
    target = File.join(@directory, "unrelated.json")
    File.binwrite(target, "cudze dane")
    [data_file, data_file + ".lock"].each do |link|
      File.link(target, link)
      begin
        error_code(:unsafe_path) { store }
        equal("cudze dane", File.binread(target))
      ensure
        File.unlink(link)
      end
    end
  end

  def test_json_parser_must_reject_duplicate_keys_instead_of_silently_ignoring_option
    store.fetch(ANNOUNCEMENTS).insert({})
    before = File.binread(data_file)
    begin
      Thread.current[:local_tables_legacy_json] = true
      error_code(:incompatible_runtime) { store }
      equal(before, File.binread(data_file))
    ensure
      Thread.current[:local_tables_legacy_json] = nil
    end
  end

  def run
    @assertions = 0
    tests = methods.grep(/^test_/).sort
    tests = tests.select { |name| name.to_s.include?(ENV["LOCAL_TABLES_TEST"]) } if ENV["LOCAL_TABLES_TEST"]
    raise ArgumentError, 'No local table tests match the requested filter' if tests.empty?
    tests.each do |name|
      GameRoomTest::TemporaryDirectory.create("tournament-local-tables-") do |directory|
        @directory = directory.tr("\\", "/")
        @actor = "Testowa Alicja"
        send(name)
      end
      puts "PASS #{name}"
    end
    puts "PASS #{tests.length} scenariuszy, #{@assertions} asercji"
  end
end

TournamentLocalTestTablesTest.new.run
