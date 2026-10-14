# encoding: UTF-8
require_relative "../support/tournament_tables"
path = File.expand_path("../../lib/tournaments/tables_gateway.rb", __dir__)
require path if File.file?(path)

class TournamentTablesGatewayTest
  include TournamentTablesTestSupport
  NAME = "tournament_registrations".freeze

  def setup(rows = [], **options)
    @account, @cancelled = "Alice", false
    @table = Table.new(rows)
    @provider = Provider.new(@table)
    assert(defined?(GameRoomTournaments::TablesGateway), "Brak implementacji TablesGateway")
    @gateway = GameRoomTournaments::TablesGateway.new(server_tables: @provider,
      user: -> { @account }, cancelled: -> { @cancelled }, **options)
  end

  class DeclaredOperationError < StandardError; end

  def test_declared_operation_errors_are_explicit_copied_and_keep_cause
    types = [DeclaredOperationError]
    setup([], operation_error_classes: types)
    types.clear
    failure = DeclaredOperationError.new('utracony odczyt')
    @table.on_select = ->(*) { raise failure }
    error = raises(GameRoomTournaments::TablesGateway::ProviderFailure) { @gateway.read_rows(NAME) }
    equal(failure, error.cause)
    setup
    @table.on_select = ->(*) { raise failure }
    equal(failure, raises(DeclaredOperationError) { @gateway.read_rows(NAME) })
  end

  def test_declared_operation_classes_cannot_catch_no_method_or_all_standard_errors
    [nil, DeclaredOperationError, [Object], [Module.new], [StandardError], [Exception],
      [NoMethodError], [NameError], [Class.new(NoMethodError)], [DeclaredOperationError.new]].each do |types|
      raises(ArgumentError) { setup([], operation_error_classes: types) }
    end
    setup([], operation_error_classes: [DeclaredOperationError])
    failure = NoMethodError.new('błąd kodu, nie I/O')
    @table.on_insert = ->(*) { raise failure }
    equal(failure, raises(NoMethodError) { @gateway.append(NAME, {"kind" => "join"}) })
    equal(1, @table.inserts.length)
  end

  def test_access_and_context_guard_every_boundary
    [:fetch, :snapshot, :page].each do |boundary|
      [:unavailable, :account, :cancelled].each do |change|
        setup([record(1)])
        mutation = lambda do
          @provider.available = false if change == :unavailable
          @account.replace("Bob") if change == :account
          @cancelled = true if change == :cancelled
        end
        if boundary == :fetch
          @provider.on_fetch = mutation
        else
          @table.on_select = lambda do |_query, index|
            mutation.call if index == (boundary == :snapshot ? 1 : 2)
            [record(1)]
          end
        end
        error = raises(StandardError) { @gateway.read_rows(NAME) }
        assert(error.class.name.start_with?("GameRoomTournaments::TablesGateway::"))
        equal(boundary == :fetch ? 0 : boundary == :snapshot ? 1 : 2, @table.selects.length)
      end
    end
  end

  def test_unavailable_or_cancelled_or_missing_account_never_fetches
    [false, nil, "", "  ", :cancelled].each do |condition|
      setup
      @provider.available = false if condition == false
      @account = condition if [nil, "", "  "].include?(condition)
      @cancelled = true if condition == :cancelled
      raises(StandardError) { @gateway.read_rows(NAME) }
      equal([], @provider.fetches)
    end
  end

  def test_hidden_empty_result_after_access_loss_is_not_empty_success
    setup
    @table.on_select = lambda do |_query, _index|
      @provider.available = false
      []
    end
    error = raises(StandardError) { @gateway.read_rows(NAME) }
    equal("GameRoomTournaments::TablesGateway::Unavailable", error.class.name)
  end

  def test_late_provider_failure_retains_cause_and_query_context
    setup([record(1), record(5)], page_limit: 1)
    failure = EltenLink::Error.timeout
    @table.on_select = lambda do |_query, index|
      raise failure if index == 3
      [record(index == 1 ? 5 : 1)]
    end
    error = raises(StandardError) { @gateway.read_rows(NAME) }
    equal(failure, error.cause)
    assert(error.message.include?(NAME) && error.message.include?("select"))
    equal(3, @table.selects.length)
  end

  def test_programming_error_is_not_transport_failure
    setup
    failure = NoMethodError.new("błąd implementacji dostawcy")
    @table.on_select = ->(*) { raise failure }
    equal(failure, raises(NoMethodError) { @gateway.read_rows(NAME) })
  end

  def test_short_pages_continue_and_upper_id_excludes_new_inserts
    setup([record(1), record(4), record(9)], page_limit: 1000)
    @table.cap = 1
    original = @table.method(:select)
    @table.define_singleton_method(:select) do |**query|
      result = original.call(**query)
      rows << {"__id" => 20} if selects.length == 1
      result
    end
    equal([1, 4, 9], @gateway.read_rows(NAME).map { |row| row["__id"] })
    equal(4, @table.selects.length)
  end

  def test_empty_page_is_end_even_if_upper_record_disappeared
    setup
    @table.on_select = ->(_query, index) { index == 1 ? [record(9)] : index == 2 ? [record(1)] : [] }
    equal([record(1)], @gateway.read_rows(NAME))
    equal(3, @table.selects.length)
  end

  def test_only_two_tables_and_valid_limits_are_accepted
    setup
    ["game_room_users", "room_presence", :tournament_registrations, nil].each do |name|
      raises(ArgumentError) { @gateway.read_rows(name) }
    end
    equal([], @provider.fetches)
    [{page_limit: 0}, {page_limit: 1001}, {page_limit: "2"}, {row_limit: 0},
      {row_limit: 4097}, {page_budget: 0}, {byte_limit: 0}].each do |options|
      raises(ArgumentError) { setup([], **options) }
    end
    setup
    equal([], @gateway.read_rows("tournament_announcements"))
  end

  def test_invalid_ids_and_malformed_pages_fail_closed
    ["1", 1.0, 0, -1, nil, true].each do |id|
      setup
      @table.on_select = ->(*) { [record(id)] }
      error = raises(StandardError) { @gateway.read_rows(NAME) }
      equal("GameRoomTournaments::TablesGateway::InvalidResponse", error.class.name)
    end
    [nil, {}, [nil], [record(1), record(2)]].each do |response|
      setup
      @table.on_select = ->(*) { response }
      error = raises(StandardError) { @gateway.read_rows(NAME) }
      equal("GameRoomTournaments::TablesGateway::InvalidResponse", error.class.name)
    end
  end

  def test_duplicate_conflicting_unordered_or_out_of_window_ids_fail
    [[record(1), record(1)], [record(1), record(1, operation_key: "conflict")],
      [record(2), record(1)], [record(10)], [record(9, operation_key: "changed")]].each do |page|
      setup
      @table.on_select = lambda do |_query, index|
        raise "Zbyt wiele wywołań" if index > 3
        index == 1 ? [record(9)] : page
      end
      error = raises(StandardError) { @gateway.read_rows(NAME) }
      equal("GameRoomTournaments::TablesGateway::InvalidResponse", error.class.name)
    end
  end

  def test_stagnating_later_page_is_rejected_without_hanging
    setup
    @table.on_select = lambda do |_query, index|
      raise "Zbyt wiele wywołań" if index > 3
      index == 1 ? [record(9)] : [record(1)]
    end
    error = raises(StandardError) { @gateway.read_rows(NAME) }
    equal("GameRoomTournaments::TablesGateway::InvalidResponse", error.class.name)
    equal(3, @table.selects.length)
  end

  def test_row_page_and_byte_budgets_are_errors_not_truncation
    [{row_limit: 2}, {page_budget: 2}, {byte_limit: 200}].each do |options|
      setup([record(1), record(2), record(3)], page_limit: 1, **options)
      error = raises(StandardError) { @gateway.read_rows(NAME) }
      equal("GameRoomTournaments::TablesGateway::LimitExceeded", error.class.name)
    end
    setup([record(1), record(2)], row_limit: 2, page_limit: 1)
    equal([record(1), record(2)], @gateway.read_rows(NAME))
  end

  def test_where_id_is_not_overwritten_and_inputs_remain_unchanged
    setup([record(1), record(2), record(3)])
    where = {"__id" => 2}
    equal([record(2)], @gateway.read_rows(NAME, where: where))
    equal({"__id" => 2}, where)
    equal([record(2), record(3)], @gateway.read_rows(NAME, where: {"__id" => {"gte" => 2, "lte" => 3}}))
    [{__id: 2}, {"__id" => "2"}, {"__id" => {"gt" => 1}}, []].each do |invalid|
      raises(ArgumentError) { @gateway.read_rows(NAME, where: invalid) }
    end
  end

  def test_append_returns_only_fresh_exact_record_and_keeps_server_metadata
    setup([record(1)])
    values = {"operation_key" => "join-2", "tournament_id" => 77, "kind" => "join"}
    result = @gateway.append(NAME, values)
    equal(values.merge("__id" => 2, "__insertion_user" => "Alice", "__insertion_time" => 1_800_000_000), result)
    equal([values], @table.inserts)
    assert(!@table.selects.empty?, "Brak świeżego odczytu po insert")
    assert(@table.selects.all? { |query| query[:where] == {"__id" => 2} })
    equal(values, @table.inserts.first)
  end

  def test_append_invalid_json_or_system_keys_never_reaches_provider
    cycle = []; cycle << cycle
    invalid = [nil, [], {kind: "join"}, {"__id" => 1}, {"nested" => {"__insertion_user" => "Bob"}},
      {"v" => Float::NAN}, {"v" => Object.new}, {"v" => cycle}, {"v" => "x" * 65_537}]
    invalid.each do |values|
      setup
      error = raises(StandardError) { @gateway.append(NAME, values) }
      assert(error.is_a?(ArgumentError) || error.class.name.end_with?("LimitExceeded"))
      equal([], @provider.fetches)
      equal([], @table.inserts)
    end
    setup
    raises(ArgumentError) { @gateway.append("game_room_users", {"kind" => "join"}) }
    equal([], @provider.fetches)
  end

  def test_append_nil_or_invalid_ack_is_unconfirmed_and_keeps_reconciliation_data
    [nil, true, 1, {}, record("1"), record(1, __insertion_user: "Bob"),
      record(1, __insertion_time: "2026-10-01"), record(1, __insertion_time: 1.0),
      record(1, __insertion_time: -1), record(1, operation_key: "wrong")].each do |response|
      setup
      @table.on_insert = ->(*) { response }
      values = {"operation_key" => "operation-1"}
      error = raises(StandardError) { @gateway.append(NAME, values) }
      equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
      equal(NAME, error.table_name)
      equal("Alice", error.account)
      equal(values, error.values)
      assert(error.cause, "Brak przyczyny niepewności")
      values["operation_key"].replace("caller-mutated")
      equal("operation-1", error.values["operation_key"])
      equal(1, @table.inserts.length)
    end
  end

  def test_append_accepted_then_timeout_is_not_retried
    setup
    failure = EltenLink::Error.timeout
    @table.on_insert = lambda do |values|
      @table.rows << values.merge("__id" => 1)
      raise failure
    end
    error = raises(StandardError) { @gateway.append(NAME, {"operation_key" => "operation-1"}) }
    equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
    equal(failure, error.cause.cause)
    equal(1, @table.inserts.length)
    equal(1, @table.rows.length)
    equal([], @table.selects)
  end

  def test_append_missing_or_mismatched_readback_never_confirms
    [[], [record(2)], [record(1, operation_key: "wrong")], [record(1, __insertion_user: "Bob")],
      [record(1, __insertion_time: "1800000000")], [record(1, __insertion_time: 1_800_000_001)],
      [record(1).reject { |key, _value| key == "__insertion_time" }],
      [record(1, extra_client_field: 1)], [record(1), record(1)]].each do |response|
      setup
      @table.on_select = ->(*) { response }
      error = raises(StandardError) { @gateway.append(NAME, {"operation_key" => "operation-1"}) }
      equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
      equal(1, error.attempted_id)
      equal(1, @table.inserts.length)
    end
  end

  def test_append_context_loss_after_insert_or_readback_is_unconfirmed
    [:insert, :fetch_readback, :readback, :final_read].each do |boundary|
      [:account, :cancelled, :unavailable].each do |change|
        setup
        mutation = lambda do
          @account = "Bob" if change == :account
          @cancelled = true if change == :cancelled
          @provider.available = false if change == :unavailable
        end
        @table.on_insert = lambda do |_values|
          mutation.call if boundary == :insert
          record(1)
        end
        @provider.on_fetch = -> { mutation.call if boundary == :fetch_readback && @provider.fetches.length == 2 }
        @table.on_select = lambda do |_query, index|
          mutation.call if boundary == :readback || (boundary == :final_read && index == 2)
          [record(1)]
        end
        error = raises(StandardError) { @gateway.append(NAME, {"operation_key" => "operation-1"}) }
        equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
        equal(1, @table.inserts.length)
      end
    end
  end

  def test_append_preflight_context_loss_is_not_mislabeled_as_sent
    setup
    @provider.on_fetch = -> { @cancelled = true }
    error = raises(StandardError) { @gateway.append(NAME, {"kind" => "join"}) }
    equal("GameRoomTournaments::TablesGateway::Cancelled", error.class.name)
    equal([], @table.inserts)
  end

  def test_append_readback_uses_same_budgets_and_keeps_late_error
    [{page_budget: 1}, {byte_limit: 200}].each do |options|
      setup([], **options)
      error = raises(StandardError) { @gateway.append(NAME, {"operation_key" => "operation-1"}) }
      equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
      equal("GameRoomTournaments::TablesGateway::LimitExceeded", error.cause.class.name)
      equal(1, @table.inserts.length)
    end
    setup
    failure = Timeout::Error.new("timeout potwierdzenia")
    @table.on_select = ->(*) { raise failure }
    error = raises(StandardError) { @gateway.append(NAME, {"publication_key" => "publish-1"}) }
    equal("GameRoomTournaments::TablesGateway::UnconfirmedWrite", error.class.name)
    equal(failure, error.cause.cause)
    equal("publish-1", error.values["publication_key"])
  end

  def test_aggregate_json_byte_budget_is_checked_before_provider
    setup([], byte_limit: 200)
    payload = {"a" => "x" * 100, "b" => "x" * 100}
    raises(GameRoomTournaments::TablesGateway::LimitExceeded) { @gateway.append(NAME, payload) }
    equal([], @provider.fetches)
    raises(GameRoomTournaments::TablesGateway::LimitExceeded) { @gateway.read_rows(NAME, where: payload) }
    equal([], @provider.fetches)
  end

  def test_native_sdk_with_real_provider_keeps_select_and_insert_contract
    memory = Table.new([record(1)])
    client = MemoryClient.new do |method, path, params|
      if path.include?("/game_room_users/")
        {"rows" => []}
      elsif method == "GET"
        {"rows" => memory.select(where: JSON.parse(params.fetch("where")),
          order: JSON.parse(params.fetch("order")), limit: params.fetch("limit"))}
      elsif method == "POST"
        {"row" => memory.insert(params.fetch("values"))}
      else
        raise "Niedozwolone wywołanie atrapy klienta"
      end
    end
    provider = GameRoomServerTables.new(Struct.new(:server_app_uuid).new("test-only-uuid"), client: client)
    assert(provider.check_access(username: "Alice"))
    provider.define_singleton_method(:check_access) { |**| raise "Gateway nie może sprawdzać dostępu" }
    gateway = GameRoomTournaments::TablesGateway.new(server_tables: provider, user: -> { "Alice" })
    equal([record(1)], gateway.read_rows(NAME))
    values = {"publication_key" => "publication-2"}
    equal(values, gateway.append("tournament_announcements", values).reject { |key, _| key.start_with?("__") })
    equal(1, client.calls.count { |method, _path, _params| method == "POST" })
    assert(client.calls.all? { |_method, _path, params| params.keys.none? { |key| key.start_with?("stamp_") } })
  end

  def test_native_provider_stamp_denial_stops_following_reads_and_writes
    deny = false
    failure = EltenLink::Error.new(code: GameRoomServerTables::STAMP_REQUIRED)
    client = MemoryClient.new { |*| raise failure if deny; {"rows" => []} }
    provider = GameRoomServerTables.new(Struct.new(:server_app_uuid).new("test-only-uuid"), client: client)
    assert(provider.check_access(username: "Alice"))
    gateway = GameRoomTournaments::TablesGateway.new(server_tables: provider, user: -> { "Alice" })
    deny = true
    error = raises(GameRoomTournaments::TablesGateway::Unavailable) { gateway.read_rows(NAME) }
    equal(failure, error.cause)
    assert(provider.stamp_required?)
    count = client.calls.length
    raises(GameRoomTournaments::TablesGateway::Unavailable) { gateway.read_rows(NAME) }
    raises(GameRoomTournaments::TablesGateway::Unavailable) { gateway.append(NAME, {"kind" => "join"}) }
    equal(count, client.calls.length)
  end

  def test_native_provider_hidden_empty_response_after_access_reset_is_failure
    client = MemoryClient.new { |*| {"rows" => []} }
    provider = GameRoomServerTables.new(Struct.new(:server_app_uuid).new("test-only-uuid"), client: client)
    assert(provider.check_access(username: "Alice"))
    provider.define_singleton_method(:perform) do |default: nil, &block|
      reset_access!
      super(default: default, &block)
    end
    gateway = GameRoomTournaments::TablesGateway.new(server_tables: provider, user: -> { "Alice" })
    raises(GameRoomTournaments::TablesGateway::Unavailable) { gateway.read_rows(NAME) }
    equal(1, client.calls.length)
  end

  def test_default_limits_accept_4096_rows_and_refuse_overflow
    rows = (1..4096).map { |id| record(id) }
    setup(rows)
    equal(rows, @gateway.read_rows(NAME))
    setup(rows + [record(4097)])
    raises(GameRoomTournaments::TablesGateway::LimitExceeded) { @gateway.read_rows(NAME) }
    setup((1..300).map { |id| record(id) }, page_limit: 1)
    raises(GameRoomTournaments::TablesGateway::LimitExceeded) { @gateway.read_rows(NAME) }
    equal(GameRoomTournaments::TablesGateway::MAX_PAGES, @table.selects.length)
  end

  def test_raw_read_is_detached_and_preserves_all_system_metadata
    row = record(1, __access: {"owner" => true}, __last_update_time: 1_800_000_001, nested: {"v" => [1, true, nil]})
    setup([row])
    result = @gateway.read_rows(NAME)
    equal([row], result)
    result.first["nested"]["v"] << "zmiana"
    equal([1, true, nil], row["nested"]["v"])
  end

  def test_append_provider_mutation_cannot_change_reconciliation_payload
    setup
    @table.on_insert = lambda do |values|
      values["nested"]["v"].replace("zmiana dostawcy")
      nil
    end
    values = {"operation_key" => "op", "nested" => {"v" => "oryginał"}}
    error = raises(GameRoomTournaments::TablesGateway::UnconfirmedWrite) { @gateway.append(NAME, values) }
    equal(values, error.values)
    assert(error.values.frozen? && error.values["nested"]["v"].frozen?)
    equal("oryginał", values["nested"]["v"])
  end

  def test_append_programming_errors_propagate_without_retry
    setup
    failure = NoMethodError.new("bug inserta")
    @table.on_insert = ->(*) { raise failure }
    equal(failure, raises(NoMethodError) { @gateway.append(NAME, {"kind" => "join"}) })
    equal(1, @table.inserts.length)
  end

  def test_native_provider_hidden_nil_insert_is_unconfirmed
    client = MemoryClient.new { |*| {"rows" => []} }
    provider = GameRoomServerTables.new(Struct.new(:server_app_uuid).new("test-only-uuid"), client: client)
    assert(provider.check_access(username: "Alice"))
    provider.define_singleton_method(:perform) do |default: nil, &block|
      reset_access!
      super(default: default, &block)
    end
    gateway = GameRoomTournaments::TablesGateway.new(server_tables: provider, user: -> { "Alice" })
    error = raises(GameRoomTournaments::TablesGateway::UnconfirmedWrite) { gateway.append(NAME, {"kind" => "join"}) }
    assert(error.cause.is_a?(GameRoomTournaments::TablesGateway::Unavailable))
    equal(1, client.calls.length)
  end

  def test_non_json_and_too_deep_server_data_is_rejected
    nested = "value"
    20.times { nested = [nested] }
    [Object.new, Float::INFINITY, nested, "\xFF".force_encoding("UTF-8")].each do |value|
      setup
      @table.on_select = ->(*) { [record(1, extra: value)] }
      raises(GameRoomTournaments::TablesGateway::InvalidResponse) { @gateway.read_rows(NAME) }
    end
  end

  def test_snapshot_payload_type_change_is_a_conflict
    setup
    @table.on_select = ->(_query, index) { [record(1, tournament_id: index == 1 ? 7 : 7.0)] }
    raises(GameRoomTournaments::TablesGateway::InvalidResponse) { @gateway.read_rows(NAME) }
  end

  def test_full_read_keeps_metadata_and_uses_id_boundary
    rows = [record(1), record(4), record(9)]
    setup(rows, page_limit: 2)
    equal(rows, @gateway.read_rows(NAME))
    equal([["__id", "desc"]], @table.selects.first[:order])
    equal({"__id" => {"gte" => 1}}, @table.selects[1][:where])
    equal({"__id" => {"gte" => 5}}, @table.selects[2][:where])
    equal([1, 2, 2], @table.selects.map { |query| query[:limit] })
  end

  def test_server_requires_one_operator_per_column_for_range_reads
    setup([record(1), record(2), record(3), record(4)], page_limit: 2)
    original = @table.method(:select)
    @table.define_singleton_method(:select) do |**query|
      query.fetch(:where).each_value do |value|
        raise 'Where operator must be unambiguous' if value.is_a?(Hash) && value.size != 1
      end
      original.call(**query)
    end
    equal([record(2), record(3)], @gateway.read_rows(NAME, where: {"__id" => {"gte" => 2, "lte" => 3}}))
    equal([], @gateway.read_rows(NAME, where: {"__id" => {"gte" => 5, "lte" => 6}}))
  end

  def test_server_materializes_only_known_omitted_registration_columns_as_null
    setup
    original = @table.method(:insert)
    @table.define_singleton_method(:insert) do |values|
      row = original.call(values)
      %w[account partner pairing_generation publication_generation amendment_json].each { |key| row[key] = nil }
      rows[-1] = Marshal.load(Marshal.dump(row))
      row
    end
    result = @gateway.append(NAME, {"kind" => "join"})
    equal(nil, result['partner'])
    setup
    @table.on_insert = ->(values) { record(1).merge(values).merge('unexpected' => nil) }
    raises(GameRoomTournaments::TablesGateway::UnconfirmedWrite) { @gateway.append(NAME, {"operation_key" => "operation-1", "kind" => "join"}) }
  end
end

failures = []
tests = TournamentTablesGatewayTest.instance_methods(false).grep(/^test_/).sort
tests.each do |name|
  begin
    TournamentTablesGatewayTest.new.public_send(name)
    puts "PASS #{name}"
  rescue StandardError => error
    failures << name
    warn "FAIL #{name}: #{error.class}: #{error.message}\n#{error.backtrace.first(8).join("\n")}"
  end
end
puts "#{tests.length} testów, #{failures.length} błędów"
exit(failures.empty? ? 0 : 1)
