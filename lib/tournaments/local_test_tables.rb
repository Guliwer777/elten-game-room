# encoding: UTF-8
# frozen_string_literal: true
require "json"
require "securerandom"
require "thread"
require_relative 'local_filesystem'
require "fileutils"
require_relative "strict_json"

module GameRoomTournaments
  # Jawnie tworzony sandbox; user jest wybranym aktorem TESTOWYM, nie sesją
  # serwera. Dane i lokalny zegar nie dowodzą uwierzytelnienia ani czasu serwera.
  # Nigdy nie używać jako fallbacku po odmowie sieci. Nie migruje ani nie usuwa
  # danych po przełączeniu backendu. UI/outbox musi oddzielać backend_identity.
  #
  # API: new(directory:, user: proc, clock: proc { Time.now }); fetch(String)
  # zwraca wyłącznie select(where:, order:, limit:, offset:, columns:) i insert.
  # Samo jawne utworzenie klasy i wskazanie user jest opt-in do trybu testowego.
  # user zwraca wybraną etykietę (UTF-8, 1..64 znaki / 256 bajtów, bez skrajnych spacji
  # i znaków sterujących), NIE automatycznie pobrane konto sieciowe. clock zwraca
  # Time lub nieujemne sekundy epoki UTC. Oba callbacki są odczytywane na nowo.
  # available?/access_state dotyczą poprawności aktora, nie stanu serwera/dysku.
  #
  # Format v1: {schema_version: 1, mode: "local_test", tables: {nazwa:
  # {last_id: Integer, rows: [Hash]}}}, wszystkie klucze w JSON są tekstowe.
  # ID w każdej tabeli są ciągłe od 1; last_id musi odpowiadać ostatniemu ID.
  # Nazwy __... są zastrzeżone na poziomie wiersza; dane zagnieżdżone to JSON.
  # Limit pełnego wiersza: 64 KiB, głębokość kontenerów 12, 8192 węzły z kluczami.
  # Limit całego pliku: 8 MiB, 4096 wierszy na tabelę. Nie ma automatycznej retencji.
  # Odczyt może utworzyć katalog i pusty .lock, ale nigdy nie zapisuje JSON.
  #
  # where: równość skalarów albo {"gte"=>..., "lte"=>..., "in"=>[skalary]}.
  # order: [[kolumna, "asc"/"desc"]], remisy po ID; brak/null lub mieszane typy
  # w sortowaniu/range są błędem, nie arbitralną kolejnością. columns=nil zwraca
  # całość; tablica projektuje tylko istniejące, jawnie żądane klucze (także __).
  # Błędy danych/I/O: Error#code (symbole); błędy programu callbacka nie są ukrywane.
  # Po niepewnym wyniku rename należy uzgodnić zapis odczytem, nie ponawiać w ciemno.
  #
  # Lokalny filesystem musi wspierać flock i atomowe rename. fsync pliku nie jest
  # gwarancją odporności sprzętu na utratę zasilania. Kontrole dowiązań nie zastępują
  # uprawnień OS ani ochrony przed wrogim procesem podmieniającym katalog w locie.
  # Parser musi rzeczywiście odrzucać zduplikowane klucze; inaczej fail-closed.

  class LocalTestTables
    TABLES = %w[tournament_announcements tournament_registrations].freeze
    FILE_NAME = "tournament-local-test-tables.json".freeze
    MAX_ROW_BYTES = 65_536
    MAX_FILE_BYTES = 8_388_608
    MAX_ROWS_PER_TABLE = 4096
    MAX_DEPTH = 12
    MAX_NODES = 8192
    MAX_INTEGER = (2**63) - 1
    METADATA = %w[__id __insertion_user __insertion_time].freeze

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    class Table
      def initialize(provider, name)
        @provider, @name = provider, name
      end

      def select(where: nil, order: nil, limit: nil, offset: nil, columns: nil)
        @provider.select_rows(@name, where: where, order: order, limit: limit, offset: offset, columns: columns)
      end

      def insert(values)
        @provider.insert_row(@name, values)
      end
    end
    private_constant :Table

    attr_reader :backend_identity, :last_error

    def initialize(directory:, user:, clock: proc { Time.now })
      raise Error, :invalid_test_user unless user.respond_to?(:call)
      raise Error, :invalid_clock unless clock.respond_to?(:call)

      verify_json_parser
      @directory = resolve_directory(directory).freeze
      @path = File.join(@directory, FILE_NAME).freeze
      @user, @clock = user, clock
      @backend_identity = "local_test:#{@path}".freeze
      @mutex = Mutex.new
      check_directory_chain(allow_missing: true)
      FileUtils.mkdir_p(LocalFilesystem.native(@directory), mode: 0o700)
      access { read }
    rescue SystemCallError, IOError
      raise Error, :store_io_error
    end

    def local_test?
      true
    end

    def available?
      current_actor
      true
    rescue Error => error
      @last_error = error
      false
    end

    def access_state
      available? ? :available : :unavailable
    end

    def stamp_required?
      false
    end

    def fetch(name)
      validate_table(name)
      Table.new(self, name.dup.freeze)
    rescue Error => error
      @last_error = error
      raise
    end

    def select_rows(name, where: nil, order: nil, limit: nil, offset: nil, columns: nil)
      current_actor
      validate_table(name)
      validate_query(where, order, limit, offset, columns)
      rows = access { read.fetch("tables").fetch(name).fetch("rows") }
      rows = rows.select { |row| matches?(row, where) } if where
      rows = ordered(rows, order) if order && !order.empty?
      rows = rows.drop(offset || 0)
      rows = rows.first(limit) unless limit.nil?
      rows = rows.map { |row| row.select { |key, _value| columns.include?(key) } } if columns
      rows
    rescue Error => error
      @last_error = error
      raise
    end

    def insert_row(name, values)
      # Jedno wywołanie user i kopia na granicy operacji, także przed clock/lock.
      actor = current_actor
      validate_table(name)
      validate_values(values)
      values = JSON.parse(JSON.generate(values))
      access do
        document = read
        state = document.fetch("tables").fetch(name)
        rows = state.fetch("rows")
        raise Error, :store_limit if rows.length >= MAX_ROWS_PER_TABLE

        row = values.merge("__id" => state.fetch("last_id") + 1,
          "__insertion_user" => actor, "__insertion_time" => current_time)
        validate_json(row)
        rows << row
        state["last_id"] = row["__id"]
        write(document)
        row
      end
    rescue Error => error
      @last_error = error
      raise
    end

    private

    def verify_json_parser
      StrictJson.verify!
    rescue StrictJson::IncompatibleRuntime
      raise Error, :incompatible_runtime
    end

    def resolve_directory(directory)
      unless text?(directory) && directory.match?(/[^[:space:]]/) && directory.bytesize <= 4096 &&
          !directory.match?(/[[:cntrl:]]/)
        raise Error, :invalid_directory
      end
      path = directory.tr("\\", "/")
      # Sandbox nie otwiera UNC/urządzeń ani zależnych od cwd ścieżek C:foo.
      if path.start_with?("//") || path.match?(/\A[A-Za-z]:(?!\/)/)
        raise Error, :invalid_directory
      end
      File.expand_path(path)
    end

    def path_stat(path)
      File.lstat(LocalFilesystem.native(path))
    rescue Errno::ENOENT
      nil
    end

    def check_directory_chain(allow_missing: false)
      path = @directory
      loop do
        stat = path_stat(path)
        raise Error, :unsafe_path if stat && stat.symlink?
        raise Error, :invalid_directory if stat && !stat.directory?
        raise Error, :invalid_directory if !stat && !allow_missing

        parent = File.dirname(path)
        break if parent == path

        path = parent
      end
    end

    def check_paths
      check_directory_chain
      [@path, @path + ".lock"].each do |path|
        stat = path_stat(path)
        if stat && (stat.symlink? || !stat.file? || stat.nlink > 1)
          raise Error, :unsafe_path
        end
      end
    end

    # Stały plik blokady, nie inode zastępowanego JSON. Wszystkie procesy
    # sandboxa trzymają flock od świeżego odczytu do końca rename.
    def access
      @mutex.synchronize do
        check_paths
        result = File.open(LocalFilesystem.native(@path + ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          raise IOError, "Nie uzyskano blokady sandboxa" unless lock.flock(File::LOCK_EX)

          begin
            check_paths
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
        @last_error = nil
        result
      end
    rescue SystemCallError, IOError
      @last_error = Error.new(:store_io_error)
      raise @last_error
    rescue Error => error
      @last_error = error
      raise
    end

    # Wąski kontrakt, bez domyślania się SQL: równość skalarów, AND kolumn
    # i operatorów gte/lte/in. Brak kolumny nie jest równy jawnej wartości null.
    def validate_query(where, order, limit, offset, columns)
      validate_json({"where" => where, "order" => order, "columns" => columns})
      [limit, offset].each do |value|
        raise Error, :invalid_query unless value.nil? || (value.is_a?(Integer) && value.between?(0, MAX_INTEGER))
      end
      unless columns.nil? || (columns.is_a?(Array) && columns.all? { |key| column?(key) })
        raise Error, :invalid_query
      end
      unless order.nil? || (order.is_a?(Array) && order.all? do |entry|
          entry.is_a?(Array) && entry.length == 2 && column?(entry[0]) && %w[asc desc].include?(entry[1])
        end)
        raise Error, :invalid_query
      end
      return if where.nil?

      raise Error, :invalid_query unless where.is_a?(Hash)

      where.each do |key, condition|
        raise Error, :invalid_query unless column?(key)

        validate_condition(condition)
      end
    rescue Error
      raise Error, :invalid_query
    end

    def column?(value)
      text?(value) && value.bytesize.between?(1, 128) && !value.match?(/[[:cntrl:]]/) &&
        (!value.start_with?("__") || METADATA.include?(value))
    end

    def scalar?(value)
      value.nil? || value.equal?(true) || value.equal?(false) || ordered_scalar?(value)
    end

    def ordered_scalar?(value)
      text?(value) || value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
    end

    def validate_condition(condition)
      return if scalar?(condition)
      raise Error, :invalid_query unless condition.is_a?(Hash) && !condition.empty?

      condition.each do |operator, value|
        valid = case operator
        when "in" then value.is_a?(Array) && value.all? { |item| scalar?(item) }
        when "gte", "lte" then ordered_scalar?(value)
        else false
        end
        raise Error, :invalid_query unless valid
      end
      compare(condition["gte"], condition["lte"]) if condition.key?("gte") && condition.key?("lte")
    end

    def compare(left, right)
      same_type = (left.is_a?(String) && right.is_a?(String)) ||
        (left.is_a?(Numeric) && right.is_a?(Numeric))
      raise Error, :invalid_query unless same_type

      left <=> right
    end

    def matches?(row, where)
      where.all? do |key, condition|
        next false unless row.key?(key)
        next row[key] == condition unless condition.is_a?(Hash)

        condition.all? do |operator, value|
          case operator
          when "in" then value.include?(row[key])
          when "gte" then compare(row[key], value) >= 0
          when "lte" then compare(row[key], value) <= 0
          end
        end
      end
    end

    def ordered(rows, order)
      order.each do |key, _direction|
        raise Error, :invalid_query unless rows.all? { |row| ordered_scalar?(row[key]) }
      end
      # ID jest stabilnym rozstrzygnięciem remisów, także przy wielu kolumnach.
      rows.sort do |left, right|
        result = 0
        order.each do |key, direction|
          result = compare(left[key], right[key])
          result = -result if direction == "desc"
          break unless result.zero?
        end
        result.zero? ? left["__id"] <=> right["__id"] : result
      end
    end

    def validate_table(name)
      raise Error, :invalid_table unless name.is_a?(String) && TABLES.include?(name)
    end

    def text?(value)
      value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? &&
        (value.encoding == Encoding::UTF_8 || value.ascii_only?)
    end

    def actor?(value)
      text?(value) && value.length.between?(1, 64) && value.bytesize <= 256 &&
        !value.match?(/\A[[:space:]]|[[:space:]]\z/) &&
        value.match?(/[^[:space:]]/) && !value.match?(/[[:cntrl:]\u2028\u2029]/)
    end

    def current_actor
      value = @user.call
      raise Error, :invalid_test_user unless actor?(value)

      value.dup.freeze
    end

    def current_time
      value = @clock.call
      value = value.to_i if value.is_a?(Time)
      raise Error, :invalid_clock unless value.is_a?(Integer) && value.between?(0, MAX_INTEGER)

      value
    end

    def validate_values(values)
      raise Error, :invalid_values unless values.is_a?(Hash)

      validate_json(values)
      raise Error, :invalid_values if values.keys.any? { |key| key.start_with?("__") }
    end

    def validate_json(value)
      validate_json_value(value, 0, [0, 0])
      raise Error, :row_too_large if JSON.generate(value).bytesize > MAX_ROW_BYTES
    rescue JSON::GeneratorError, EncodingError
      raise Error, :invalid_values
    end

    def validate_json_value(value, depth, budget)
      budget[0] += 1
      raise Error, :invalid_values if budget[0] > MAX_NODES
      case value
      when Hash, Array
        raise Error, :invalid_values if depth >= MAX_DEPTH || value.size > MAX_NODES
        if value.is_a?(Hash)
          value.each do |key, child|
            raise Error, :invalid_values unless key.is_a?(String)

            validate_json_value(key, depth + 1, budget)
            validate_json_value(child, depth + 1, budget)
          end
        else
          value.each { |child| validate_json_value(child, depth + 1, budget) }
        end
      when String
        raise Error, :invalid_values unless text?(value)

        budget[1] += value.bytesize
      when Integer
        raise Error, :invalid_values unless value.between?(-MAX_INTEGER, MAX_INTEGER)
      when Float
        raise Error, :invalid_values unless value.finite?
      when NilClass, TrueClass, FalseClass
        nil
      else
        raise Error, :invalid_values
      end
      raise Error, :row_too_large if budget[1] > MAX_ROW_BYTES
    end

    def empty_document
      {"schema_version" => 1, "mode" => "local_test",
        "tables" => TABLES.to_h { |name| [name, {"last_id" => 0, "rows" => []}] }}
    end

    def validate_document(document)
      if document.is_a?(Hash) && document["schema_version"].is_a?(Integer) && document["schema_version"] != 1
        raise Error, :incompatible_schema
      end
      unless document.is_a?(Hash) && document.keys.sort == %w[mode schema_version tables] &&
          document["schema_version"].is_a?(Integer) && document["schema_version"] == 1 &&
          document["mode"] == "local_test" && document["tables"].is_a?(Hash) &&
          document["tables"].keys.sort == TABLES.sort
        raise Error, :corrupt_store
      end
      document["tables"].each_value do |state|
        unless state.is_a?(Hash) && state.keys.sort == %w[last_id rows] && state["rows"].is_a?(Array) &&
            state["last_id"].is_a?(Integer) && state["last_id"] == state["rows"].length
          raise Error, :corrupt_store
        end
        raise Error, :store_limit if state["rows"].length > MAX_ROWS_PER_TABLE

        state["rows"].each_with_index { |row, index| validate_record(row, index + 1) }
      end
      document
    end

    def validate_record(row, id)
      unless row.is_a?(Hash) && row["__id"].is_a?(Integer) && row["__id"] == id &&
          actor?(row["__insertion_user"]) && row["__insertion_time"].is_a?(Integer) &&
          row["__insertion_time"].between?(0, MAX_INTEGER) &&
          row.keys.select { |key| key.start_with?("__") }.sort == METADATA.sort
        raise Error, :corrupt_store
      end
      validate_json(row)
    rescue Error
      raise Error, :corrupt_store
    end

    def read
      begin
        payload = File.binread(LocalFilesystem.native(@path), MAX_FILE_BYTES + 1) || ""
      rescue Errno::ENOENT
        return empty_document
      end
      raise Error, :store_limit if payload.bytesize > MAX_FILE_BYTES

      parsed = StrictJson.parse(payload, max_nesting: MAX_DEPTH + 4)
      validate_document(parsed)
    rescue StrictJson::IncompatibleRuntime
      raise Error, :incompatible_runtime
    rescue JSON::ParserError, JSON::GeneratorError, EncodingError
      raise Error, :corrupt_store
    end

    def write(document)
      validate_document(document)
      payload = JSON.generate(document)
      raise Error, :store_limit if payload.bytesize > MAX_FILE_BYTES

      temporary = "#{@path}.tmp-#{SecureRandom.hex(12)}"
      created = false
      begin
        File.open(LocalFilesystem.native(temporary), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          created = true
          file.binmode
          raise IOError, "Niepełny zapis sandboxa" unless file.write(payload) == payload.bytesize

          file.flush
          file.fsync
        end
        check_paths
        File.rename(LocalFilesystem.native(temporary), LocalFilesystem.native(@path))
      ensure
        # Sprzątamy tylko własny plik, nigdy bazę ani cudze pozostałości.
        File.delete(LocalFilesystem.native(temporary)) if created && File.exist?(LocalFilesystem.native(temporary))
      end
    end
  end
end
