# encoding: UTF-8
require "json"
require "digest"
require "securerandom"
require "pathname"
require "thread"
require_relative "draft_details"

module GameRoomTournaments
  # Wyłącznie lokalne szkice. Nie jest to zapis partii ani publiczny turniej.
  class Drafts
    FIELDS = (%w[name game_id game_options format rematch] + DraftDetails::DEFAULTS.keys).freeze
    DEFAULTS = {"format" => nil, "rematch" => nil}.merge(DraftDetails::DEFAULTS).freeze
    MAX_OPTIONS_DEPTH = 8
    MAX_OPTIONS_NODES = 4096
    MAX_OPTIONS_BYTES = 65_536
    MAX_FILE_BYTES = 4_194_304

    class Invalid < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    def initialize(program, owner:)
      unless text?(owner) && owner.match?(/[^[:space:]]/) && !owner.match?(/[[:cntrl:]\u2028\u2029]/)
        raise ArgumentError, "Brak prawidłowego właściciela szkiców"
      end
      @owner = owner.strip.downcase.freeze
      root = program.data_path
      unless text?(root) && !root.empty? && !root.include?("\0")
        raise ArgumentError, "Brak prawidłowego katalogu danych programu"
      end
      root = File.expand_path(root) unless Pathname.new(root).absolute?
      @path = File.join(root, "tournament-drafts-#{Digest::SHA256.hexdigest(@owner)}.json").freeze
      @mutex = Mutex.new
    end

    def list
      access { read["drafts"] }
    end

    def fetch(id)
      list.find { |record| record["id"] == id }
    end

    def create(attributes)
      validate_input(attributes)
      attributes = DEFAULTS.merge(attributes)
      validate_attributes(attributes)
      access do
        document = read
        now = Time.now.to_i
        record = attributes.merge("id" => SecureRandom.uuid, "owner" => @owner,
          "revision" => 1, "created_at" => now, "updated_at" => now, "status" => "draft")
        document["drafts"] << record
        write(document)
        JSON.parse(JSON.generate(record))
      end
    end

    class Conflict < StandardError; end
    class Corrupt < StandardError; end

    def update(id, attributes, expected_revision:)
      validate_input(attributes)
      access do
        document = read
        record = current_record(document, id, expected_revision)
        validate_attributes(record.merge(attributes))
        record.merge!(attributes)
        record["revision"] += 1
        record["updated_at"] = [Time.now.to_i, record["updated_at"], record["created_at"]].max
        write(document)
        JSON.parse(JSON.generate(record))
      end
    end

    def delete(id, expected_revision:)
      access do
        document = read
        record = current_record(document, id, expected_revision)
        document["drafts"].delete(record)
        write(document)
        true
      end
    end

    private

    def access
      @mutex.synchronize do
        # Blokada nie może być inode'em JSON, który jest zastępowany przy zapisie.
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          raise IOError, "Nie udało się zablokować magazynu szkiców" unless lock.flock(File::LOCK_EX)
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end
    end

    def validate_input(attributes)
      unless attributes.is_a?(Hash) && attributes.keys.all? { |key| key.is_a?(String) && FIELDS.include?(key) }
        raise Invalid, :invalid_options
      end
    end

    def text?(value)
      value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? &&
        (value.encoding == Encoding::UTF_8 || value.ascii_only?)
    end

    def validate_attributes(attributes)
      name = attributes["name"]
      unless text?(name) && name.length.between?(1, 120) && name.match?(/[^[:space:]]/) && !name.match?(/[[:cntrl:]\u2028\u2029]/)
        raise Invalid, :invalid_name
      end
      game = attributes["game_id"]
      raise Invalid, :invalid_game unless text?(game) && game.match?(/\A[a-z0-9_]+\z/)
      validate_options(attributes["game_options"])
      raise Invalid, :invalid_format unless [nil, "round_robin", "groups_knockout"].include?(attributes["format"])
      rematch = attributes["rematch"]
      raise Invalid, :invalid_rematch unless rematch.nil? || rematch.equal?(true) || rematch.equal?(false)
      DraftDetails.validate!(attributes)
    rescue DraftDetails::Invalid => error
      raise Invalid, error.code
    end

    def validate_options(options)
      raise Invalid, :invalid_options unless options.is_a?(Hash)
      validate_json_value(options, 0, [0, 0])
      raise Invalid, :invalid_options if JSON.generate(options).bytesize > MAX_OPTIONS_BYTES
    rescue JSON::GeneratorError, EncodingError
      raise Invalid, :invalid_options
    end

    # Budżet węzłów i bajtów ogranicza pracę także przed serializacją JSON.
    def validate_json_value(value, depth, budget)
      budget[0] += 1
      raise Invalid, :invalid_options if budget[0] > MAX_OPTIONS_NODES
      case value
      when Hash, Array
        raise Invalid, :invalid_options if depth >= MAX_OPTIONS_DEPTH || value.size > MAX_OPTIONS_NODES
        if value.is_a?(Hash)
          value.each do |key, child|
            raise Invalid, :invalid_options unless key.is_a?(String)
            validate_json_value(key, depth + 1, budget)
            validate_json_value(child, depth + 1, budget)
          end
        else
          value.each { |child| validate_json_value(child, depth + 1, budget) }
        end
      when String
        raise Invalid, :invalid_options unless text?(value)
        budget[1] += value.bytesize
      when Integer
        raise Invalid, :invalid_options if value.bit_length > MAX_OPTIONS_BYTES * 4
        budget[1] += value.to_s.bytesize
      when Float
        raise Invalid, :invalid_options unless value.finite?
      when NilClass, TrueClass, FalseClass
        nil
      else
        raise Invalid, :invalid_options
      end
      raise Invalid, :invalid_options if budget[1] > MAX_OPTIONS_BYTES
    end

    def current_record(document, id, revision)
      record = document["drafts"].find { |entry| entry["id"] == id }
      unless record && revision.is_a?(Integer) && revision == record["revision"]
        raise Conflict, "Szkic usunięto albo zmieniono; odśwież listę"
      end
      record
    end

    RECORD_FIELDS = (FIELDS + %w[id owner revision created_at updated_at status]).freeze
    LEGACY_RECORD_FIELDS = (RECORD_FIELDS - DraftDetails::DEFAULTS.keys).freeze
    GROUP_FIELDS = %w[group_count places_per_group group_advancement].freeze
    V2_RECORD_SHAPES = [RECORD_FIELDS, RECORD_FIELDS - GROUP_FIELDS,
      RECORD_FIELDS - ['group_advancement']].map { |fields| fields.sort.freeze }.freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    def validate_document(document)
      unless document.is_a?(Hash) && document.keys.sort == %w[drafts owner schema_version] &&
          document["schema_version"].is_a?(Integer) && [1, 2].include?(document["schema_version"]) &&
          document["owner"] == @owner && document["drafts"].is_a?(Array)
        raise Corrupt, "Nieprawidłowy schemat lub właściciel magazynu szkiców"
      end
      shapes = document["schema_version"] == 1 ? [LEGACY_RECORD_FIELDS.sort] : V2_RECORD_SHAPES
      ids = {}
      document["drafts"].each do |record|
        unless record.is_a?(Hash) && shapes.include?(record.keys.sort) &&
            record["id"].is_a?(String) && UUID.match?(record["id"]) && !ids[record["id"]] &&
            record["owner"] == @owner && record["status"] == "draft" &&
            record["revision"].is_a?(Integer) && record["revision"] > 0 &&
            record["created_at"].is_a?(Integer) && record["created_at"] >= 0 &&
            record["updated_at"].is_a?(Integer) && record["updated_at"] >= record["created_at"]
          raise Corrupt, "Nieprawidłowy rekord szkicu"
        end
        validate_attributes(record)
        ids[record["id"]] = true
      end
      document
    rescue Invalid
      raise Corrupt, "Nieprawidłowe atrybuty zapisanego szkicu"
    end

    def write(document)
      validate_document(document)
      payload = JSON.generate(document)
      raise Invalid, :invalid_options if payload.bytesize > MAX_FILE_BYTES
      temporary = "#{@path}.tmp-#{SecureRandom.hex(12)}"
      created = false
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          created = true
          file.binmode
          file.write(payload)
          file.flush
          file.fsync
        end
        backup_legacy if @legacy_payload
        File.rename(temporary, @path)
      ensure
        File.delete(temporary) if created && File.exist?(temporary)
      end
    end

    def backup_legacy
      backup = "#{@path}.v#{@legacy_schema}-#{Digest::SHA256.hexdigest(@legacy_payload)}.bak"
      created = false
      completed = false
      begin
        File.open(backup, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          created = true
          file.binmode
          unless file.write(@legacy_payload) == @legacy_payload.bytesize
            raise IOError, "Niepełny zapis kopii szkiców"
          end
          file.flush
          file.fsync
        end
        completed = true
      ensure
        # Sprzątamy wyłącznie nieukończony plik utworzony przez tę próbę.
        File.delete(backup) if created && !completed && File.exist?(backup)
      end
    rescue Errno::EEXIST
      # Nie nadpisujemy wcześniejszej kopii, nawet pod oczekiwaną sumą SHA256.
      File.open(backup, File::RDWR) do |file|
        file.binmode
        unless file.read(MAX_FILE_BYTES + 1) == @legacy_payload
          raise IOError, "Istniejąca kopia szkiców ma inną zawartość"
        end
        file.flush
        file.fsync
      end
    end

    def read
      @legacy_payload = nil
      @legacy_schema = nil
      begin
        payload = File.binread(@path, MAX_FILE_BYTES + 1) || ""
        raise Corrupt, "Magazyn szkiców przekracza limit odczytu" if payload.bytesize > MAX_FILE_BYTES
      rescue Errno::ENOENT
        return {"schema_version" => 2, "owner" => @owner, "drafts" => []}
      end
      document = validate_document(JSON.parse(payload, create_additions: false))
      if document["schema_version"] == 1 || document['drafts'].any? { |record| record.keys.sort != RECORD_FIELDS.sort }
        @legacy_payload = payload
        @legacy_schema = document['schema_version']
        # Dopiero po ścisłym sprawdzeniu wszystkich starych rekordów.
        document["drafts"] = document["drafts"].map do |record|
          defaults = DraftDetails::DEFAULTS.transform_values { |value| value.is_a?(Array) ? value.dup : value }
          defaults.merge(record)
        end
        document["schema_version"] = 2
      end
      document
    rescue JSON::ParserError, EncodingError
      raise Corrupt, "Nieprawidłowy JSON magazynu szkiców"
    end
  end
end
