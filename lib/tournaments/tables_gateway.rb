# encoding: UTF-8
require "json"
require "timeout"

module GameRoomTournaments
  # Górne ID ogranicza zbiór, ale SDK nie obiecuje transakcyjnego snapshotu:
  # równoległa zmiana/usunięcie lub opóźniona widoczność mogą zmienić odczyt.
  # Bramka nie wdraża schematu ani nie uruchamia check_access.
  class TablesGateway
    TABLES = %w[tournament_announcements tournament_registrations].freeze
    MAX_ROWS = 4096
    MAX_PAGES = 256
    MAX_BYTES = 8_388_608
    MAX_PAYLOAD_BYTES = 65_536
    REGISTRATION_OPTIONAL_COLUMNS = %w[account partner pairing_generation publication_generation amendment_json].freeze

    class Error < StandardError; end
    class Unavailable < Error; end
    class ContextChanged < Error; end
    class Cancelled < Error; end
    class ProviderFailure < Error; end
    class InvalidResponse < Error; end
    class LimitExceeded < Error; end

    # Niepewność wymaga uzgodnienia operation_key/publication_key przez wyższą
    # warstwę. Ten błąd nigdy nie upoważnia do automatycznego ponowienia insertu.
    class UnconfirmedWrite < Error
      attr_reader :table_name, :account, :values, :attempted_id

      def initialize(table_name:, account:, values:, attempted_id:, reason:)
        @table_name, @account, @values, @attempted_id = table_name, account, values, attempted_id
        super("#{table_name}: zapis niepotwierdzony (#{reason.class}: #{reason.message})")
      end
    end

    # Wstrzykiwany provider: available?, fetch(name), Table#select/#insert.
    # Nie wymaga konkretnej klasy, nie wybiera ani nie przełącza backendu.
    # operation_error_classes: jawne, wąskie klasy błędów operacyjnych providera.
    # Własne wyjątki wskazuje kompozycja; bramka nie ładuje modułu providera.
    # Lista jest kopiowana; NoMethodError i jego przodkowie są zabronieni.
    # Limity stron/bajtów obejmują również snapshot i potwierdzenie zapisu;
    # limit wierszy dotyczy wyniku odczytu. Nie ma cache ani retry.
    def initialize(server_tables:, user:, cancelled: nil, page_limit: 1000, row_limit: MAX_ROWS,
      page_budget: MAX_PAGES, byte_limit: MAX_BYTES, operation_error_classes: [])
      @operation_error_classes = operation_errors!(operation_error_classes)
      @server_tables, @user, @cancelled = server_tables, user, cancelled
      @page_limit = limit!(page_limit, 1000)
      @row_limit = limit!(row_limit, MAX_ROWS)
      @page_budget = limit!(page_budget, MAX_PAGES)
      @byte_limit = limit!(byte_limit, MAX_BYTES)
    end

    # Zwraca odizolowane surowe Hash, łącznie z polami __. Walidacja modelu
    # pozostaje po stronie wywołującego; bramka wymaga kanonicznego ID.
    def read_rows(table_name, where: {})
      name = table_name!(table_name)
      query = where!(where)
      account = current_account!
      rows = read_snapshot(name, query, account, {pages: 0, bytes: 0})
      guard!(account, "#{name} read complete")
      rows
    end

    def append(table_name, values)
      name = table_name!(table_name)
      payload, size = payload!(values)
      account = current_account!
      table = boundary(account, "#{name} fetch") { @server_tables.fetch(name) }
      sent, inserted = false, nil
      budget = {pages: 0, bytes: size}
      begin
        boundary(account, "#{name} insert") do
          sent = true
          inserted = table.insert(JSON.parse(JSON.generate(payload)))
        end
        verify_written!(inserted, payload, account, name)
        inserted, bytes = json_copy(inserted, InvalidResponse)
        budget[:bytes] += bytes
        raise LimitExceeded, "#{name}: przekroczono budżet bajtów" if budget[:bytes] > @byte_limit
        rows = read_snapshot(name, {"__id" => inserted["__id"]}, account, budget)
        raise InvalidResponse, "#{name}: brak dokładnego odczytu zapisu" unless rows.length == 1
        verified = rows.first
        verify_written!(verified, payload, account, name)
        unless verified.values_at("__id", "__insertion_user", "__insertion_time").eql?(
            inserted.values_at("__id", "__insertion_user", "__insertion_time"))
          raise InvalidResponse, "#{name}: zmienione metadane zapisu"
        end
        guard!(account, "#{name} append complete")
        verified
      rescue Error => error
        raise unless sent
        id = inserted["__id"] if inserted.is_a?(Hash) && positive_id?(inserted["__id"])
        raise UnconfirmedWrite.new(table_name: name, account: account, values: payload,
          attempted_id: id, reason: error)
      end
    end

    private

    def payload!(values)
      raise ArgumentError, "Zapis wymaga Hash" unless values.is_a?(Hash)
      copy, size = json_copy(values, ArgumentError, byte_cap: [@byte_limit, MAX_PAYLOAD_BYTES].min)
      raise LimitExceeded, "Zapis przekracza 65536 bajtów JSON" if size > MAX_PAYLOAD_BYTES
      reject_system_keys!(copy)
      [freeze_json(copy), size]
    end

    def reject_system_keys!(value)
      if value.is_a?(Hash)
        value.each do |key, item|
          raise ArgumentError, "Klient nie może podawać pól __" if key.start_with?("__")
          reject_system_keys!(item)
        end
      elsif value.is_a?(Array)
        value.each { |item| reject_system_keys!(item) }
      end
    end

    def freeze_json(value)
      value.each { |key, item| key.freeze; freeze_json(item) } if value.is_a?(Hash)
      value.each { |item| freeze_json(item) } if value.is_a?(Array)
      value.freeze
    end

    # Kontrakt wdrożenia: __insertion_time to integer sekund Unix UTC >= 0.
    # Nie interpretujemy dat lokalnych, tekstu, milisekund ani czasu klienta.
    # Właściciel musi potwierdzić format i niepodrabialność metadanych serwera.
    def verify_written!(row, payload, account, name)
      actual_payload = row.reject { |key, _value| key.is_a?(String) && key.start_with?("__") } if row.is_a?(Hash)
      if actual_payload && name == "tournament_registrations"
        # The server materializes omitted nullable schema columns as null.
        actual_payload = actual_payload.reject do |key, value|
          value.nil? && !payload.key?(key) && REGISTRATION_OPTIONAL_COLUMNS.include?(key)
        end
      end
      unless row.is_a?(Hash) && positive_id?(row["__id"]) && row["__insertion_user"].eql?(account) &&
          row["__insertion_time"].is_a?(Integer) && row["__insertion_time"] >= 0 &&
          row.keys.all? { |key| key.is_a?(String) } &&
          actual_payload.eql?(payload)
        raise InvalidResponse, "#{name}: niezgodne ID, autor, czas lub payload zapisu"
      end
    end

    def read_snapshot(name, where, account, budget)
      table = boundary(account, "#{name} fetch") { @server_tables.fetch(name) }
      minimum, maximum = id_bounds(where)
      snapshot_filter = where.dup
      if where["__id"].is_a?(Hash)
        snapshot_filter["__id"] = maximum ? {"lte" => maximum} : {"gte" => minimum}
      end
      snapshot = select_rows(table, name, account, budget, where: snapshot_filter, order: [["__id", "desc"]], limit: 1)
      return [] if snapshot.empty?
      upper = snapshot.first.fetch("__id")
      return [] if upper < minimum
      unless upper >= minimum && (!maximum || upper <= maximum)
        raise InvalidResponse, "#{name}: górne ID poza filtrem"
      end
      cursor, rows = minimum - 1, []
      loop do
        # AppTable accepts one operator per column. The captured upper ID is
        # enforced below; stop at it before requesting another page.
        filter = where.merge("__id" => {"gte" => cursor + 1})
        filter["__id"] = where["__id"] if where["__id"].is_a?(Integer)
        page = select_rows(table, name, account, budget, where: filter, order: [["__id", "asc"]], limit: @page_limit)
        break if page.empty?
        page.each do |row|
          id = row.fetch("__id")
          unless id > cursor && id <= upper
            raise InvalidResponse, "#{name}: duplikat/konflikt ID, brak postępu lub ID poza granicą"
          end
          if id == upper && !row.eql?(snapshot.first)
            raise InvalidResponse, "#{name}: zmieniony rekord górnej granicy"
          end
          raise LimitExceeded, "#{name}: przekroczono limit wierszy" if rows.length >= @row_limit
          rows << row
          cursor = id
          break if cursor == upper
        end
        # Krótka strona nie jest końcem. Każde żądanie ma wspólny budżet.
        break if cursor == upper
      end
      rows
    end

    def select_rows(table, name, account, budget, **query)
      raise LimitExceeded, "#{name}: przekroczono budżet stron" if budget[:pages] >= @page_budget
      budget[:pages] += 1
      result = boundary(account, "#{name} select #{budget[:pages]}") { table.select(**query) }
      unless result.is_a?(Array) && result.length <= query.fetch(:limit) &&
          result.all? { |row| row.is_a?(Hash) && positive_id?(row["__id"]) }
        raise InvalidResponse, "#{name}: nieprawidłowa strona lub ID"
      end
      rows, size = json_copy(result, InvalidResponse)
      budget[:bytes] += size
      raise LimitExceeded, "#{name}: przekroczono budżet bajtów" if budget[:bytes] > @byte_limit
      rows
    end

    def table_name!(name)
      raise ArgumentError, "Dozwolone wyłącznie dwie tabele turniejów" unless name.is_a?(String) && TABLES.include?(name)
      name.dup.freeze
    end

    def limit!(value, maximum)
      raise ArgumentError, "Limit musi być dodatnim integer <= #{maximum}" unless value.is_a?(Integer) && value.between?(1, maximum)
      value
    end

    def positive_id?(value)
      value.is_a?(Integer) && value > 0
    end

    def where!(where)
      raise ArgumentError, "where musi być Hash" unless where.is_a?(Hash)
      copy, = json_copy(where, ArgumentError)
      id_bounds(copy)
      copy
    end

    def id_bounds(where)
      return [1, nil] unless where.key?("__id")
      value = where["__id"]
      return [value, value] if positive_id?(value)
      unless value.is_a?(Hash) && !value.empty? && (value.keys - %w[gte lte]).empty? && value.values.all? { |id| positive_id?(id) }
        raise ArgumentError, "Filtr __id wymaga dodatniego integer lub gte/lte"
      end
      lower, upper = value.fetch("gte", 1), value["lte"]
      raise ArgumentError, "Odwrócony zakres __id" if upper && upper < lower
      [lower, upper]
    end

    def json_copy(value, error, byte_cap: @byte_limit)
      validate_json!(value, error, 0, [0, 0], byte_cap)
      text = JSON.generate(value, max_nesting: 20)
      raise LimitExceeded, "Przekroczono budżet bajtów JSON" if text.bytesize > byte_cap
      [JSON.parse(text), text.bytesize]
    rescue JSON::GeneratorError, JSON::ParserError => failure
      raise error, "Nieprawidłowy JSON: #{failure.message}"
    end

    def validate_json!(value, error, depth, count, byte_cap)
      count[0] += 1
      count[1] += 1
      raise error, "Przekroczono złożoność JSON" if depth > 16 || count[0] > 65_536
      raise LimitExceeded, "Przekroczono budżet bajtów JSON" if count[1] > byte_cap
      case value
      when Hash
        value.each do |key, item|
          raise error, "Klucze JSON muszą być String" unless key.is_a?(String)
          validate_json!(key, error, depth + 1, count, byte_cap)
          validate_json!(item, error, depth + 1, count, byte_cap)
        end
      when Array
        value.each { |item| validate_json!(item, error, depth + 1, count, byte_cap) }
      when String
        raise error, "Nieprawidłowy tekst JSON" unless value.valid_encoding?
        count[1] += value.bytesize
        raise LimitExceeded, "Przekroczono budżet bajtów JSON" if count[1] > byte_cap
      when Float
        raise error, "Nieskończona liczba JSON" unless value.finite?
      when Integer
        raise LimitExceeded, "Liczba przekracza budżet JSON" if value.bit_length > byte_cap * 4
        count[1] += value.to_s.bytesize
        raise LimitExceeded, "Przekroczono budżet bajtów JSON" if count[1] > byte_cap
      when TrueClass, FalseClass, NilClass
        nil
      else
        raise error, "Nieobsługiwany typ JSON"
      end
    end

    def current_account!
      value = @user.call
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty?
        raise ContextChanged, "Brak bieżącego konta klienta"
      end
      value.dup.freeze
    end

    def guard!(account, context)
      raise Cancelled, "#{context}: anulowano" if @cancelled && @cancelled.call
      raise ContextChanged, "#{context}: zmieniono konto" unless @user.call == account
      raise Unavailable, "#{context}: tabele niedostępne" unless @server_tables.available?
    end

    def boundary(account, context)
      guard!(account, context)
      begin
        result = yield
      rescue *provider_errors => error
        guard!(account, context)
        raise ProviderFailure, "#{context}: #{error.class}: #{error.message}"
      end
      guard!(account, context)
      result
    end

    def operation_errors!(types)
      unless types.is_a?(Array) && types.all? { |type| type.is_a?(Class) && type < StandardError &&
          !(NoMethodError <= type || type <= NoMethodError) }
        raise ArgumentError, "Wymagane wąskie klasy błędów operacyjnych, bez NoMethodError"
      end
      types.dup.freeze
    end

    def provider_errors
      types = [Timeout::Error, IOError, SystemCallError] + @operation_error_classes
      types << EltenLink::Error if defined?(EltenLink::Error)
      types
    end
  end
end
