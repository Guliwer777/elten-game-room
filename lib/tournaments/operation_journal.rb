# encoding: UTF-8
# frozen_string_literal: true
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'thread'
require_relative 'local_filesystem'
require_relative 'server_plan_document'

module GameRoomTournaments
  # Trwały zamiar PRZED insertem. Nie wykonuje sieci ani ponawiania operacji.
  # Zakres: owner (małe litery, 1..64 znaki / 256 B) + niezmieniona opaque
  # backend_identity (1..4096 B). Tożsamość backendu nie jest ścieżką do migracji.
  # Odczyt może utworzyć katalog/.lock, nigdy JSON. Każdy odczyt sprawdza cały
  # dokument schema 1; nie naprawia, nie zeruje i nie usuwa obcych danych.
  #
  # prepare zachowuje pierwszy klucz i porównuje pozostały payload przez eql?.
  # claim zwraca zamrożony attempted tylko zwycięzcy; brak ID lub już zajęty
  # zamiar zwraca nil. Resolve wymaga bieżącej rewizji i jawnego końcowego stanu.
  # Dowód końcowy to Hash z ograniczonym JSON; nil tylko w prepared/attempted.
  # Znaczenie dowodu sprawdza wywołujący, nie magazyn. Terminalny stan pozwala
  # tylko na ten sam stan lub conflict. Zły korzeń w resolve: Invalid
  # (:invalid_evidence); w zapisanym dokumencie: Corrupt, bez naprawy.
  # No generic reset/delete/retry or clock dependency. Explicit presence-only
  # retention keeps 128 confirmations/expired leases, never unresolved operations.
  #
  # Limity: 4096 operacji, 8 MiB pliku, 160000 B payloadu i 16384 B dowodu
  # (włącznie ze składnią JSON); 12 poziomów kontenerów / 8192 węzły z kluczami
  # osobno dla payloadu, dowodu i zagnieżdżonych settings_json/schedule_json.
  # Ustawienia i harmonogram są obiektami JSON, bez interpretacji zasad gry.
  #
  # Wymaga flock, atomowego rename i parsera faktycznie odrzucającego duplikaty.
  # Kontrole istniejących dowiązań nie zastępują uprawnień OS ani ochrony przed
  # wrogą podmianą katalogów w trakcie operacji. Fsync nie gwarantuje odporności
  # sprzętu na zanik zasilania. Awaria PO rename może oznaczać dokonany zapis:
  # trzeba odczytać stan, nigdy powtarzać wysyłki po niepewnym claim.
  class OperationJournal
    TABLES = {'publication' => 'tournament_announcements', 'join' => 'tournament_registrations', 'withdrawal' => 'tournament_registrations', 'removal' => 'tournament_registrations', 'pairing' => 'tournament_registrations', 'amendment' => 'tournament_registrations', 'cancellation' => 'tournament_registrations', 'plan_document' => 'tournament_plan_documents', 'invitation' => 'tournament_registrations', 'invite_declined' => 'tournament_registrations'}.freeze
    PUBLICATION_FIELDS = %w[publication_key schema_version title game rules settings_json schedule_json
      registration_opens_at registration_closes_at timezone].freeze
    MAX_INTEGER = (2**63) - 1
    MAX_DEPTH = 12
    MAX_NODES = 8192
    MAX_PAYLOAD_BYTES = 160_000
    MAX_PLAN_PAYLOAD_BYTES = ServerPlanDocument::MAX_BYTES * 2 + 4096
    MAX_EVIDENCE_BYTES = 16_384
    MAX_OPERATIONS = 4096
    MAX_FILE_BYTES = 8_388_608

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end
    class Invalid < Error; end
    class Corrupt < Error; end
    class Conflict < Error; end

    attr_reader :owner, :backend_identity, :path

    def initialize(directory:, owner:, backend_identity:)
      verify_json_parser
      raise Invalid, :invalid_owner unless owner?(owner)
      unless bounded_text?(backend_identity, 4096)
        raise Invalid, :invalid_backend_identity
      end
      @owner = owner.downcase.freeze
      raise Invalid, :invalid_owner unless owner?(@owner)
      @backend_identity = backend_identity.dup.freeze
      @directory = resolve_directory(directory).freeze
      digest = Digest::SHA256.hexdigest(JSON.generate([@owner, @backend_identity]))
      @path = File.join(@directory, "tournament-operations-#{digest}.json").freeze
      @mutex = Mutex.new
      check_directory_chain(allow_missing: true)
      FileUtils.mkdir_p(LocalFilesystem.native(@directory), mode: 0o700)
      check_paths
    rescue SystemCallError, IOError
      raise Error, :journal_io_error
    end

    def list
      access { freeze_tree(read['operations']) }
    end

    def fetch(id)
      list.find { |record| record['id'] == id }
    end

    def find(kind:, intent_id:)
      list.find { |record| record['kind'] == kind && record['intent_id'] == intent_id }
    end

    def prepare(kind:, intent_id:, values:)
      validate_intent(kind, intent_id)
      kind, intent_id = kind.dup, intent_id.dup
      validate_values(kind, values)
      values = JSON.parse(JSON.generate(values))
      access do
        document = read
        existing = document['operations'].find { |entry| entry['kind'] == kind && entry['intent_id'] == intent_id }
        if existing
          key = kind == 'publication' ? 'publication_key' : 'operation_key'
          content = values.reject { |field, _value| field == key }
          original = existing['values'].reject { |field, _value| field == key }
          raise Conflict, :intent_conflict unless original.eql?(content)
          next freeze_tree(existing)
        end
        raise Invalid, :operation_limit if document['operations'].length >= MAX_OPERATIONS

        record = {'id' => SecureRandom.uuid, 'revision' => 1, 'status' => 'prepared',
          'kind' => kind.dup, 'intent_id' => intent_id.dup, 'table_name' => TABLES.fetch(kind),
          'values' => values, 'evidence' => nil}
        document['operations'] << record
        write(document)
        freeze_tree(record)
      end
    end

    # Wyłączne prawo do jednej próby; restart nigdy go nie przywraca.
    def claim(id)
      id = id.dup if id.is_a?(String)
      access do
        document = read
        record = document['operations'].find { |entry| entry['id'] == id }
        next nil unless record && record['status'] == 'prepared'

        record['status'] = 'attempted'
        record['revision'] += 1
        write(document)
        freeze_tree(record)
      end
    end

    def resolve(id, status:, evidence:, expected_revision:)
      raise Invalid, :invalid_status unless %w[confirmed outside_window conflict].include?(status)
      id = id.dup if id.is_a?(String)
      status = status.dup
      unless expected_revision.is_a?(Integer) && expected_revision.between?(1, (2**63) - 1)
        raise Invalid, :invalid_revision
      end
      raise Invalid, :invalid_evidence unless evidence.is_a?(Hash)
      validate_json(evidence, MAX_EVIDENCE_BYTES, :evidence_too_large)
      evidence = JSON.parse(JSON.generate(evidence))
      access do
        document = read
        record = document['operations'].find { |entry| entry['id'] == id }
        raise Conflict, :missing_operation unless record
        raise Conflict, :revision_conflict unless record['revision'] == expected_revision
        unless %w[prepared attempted].include?(record['status']) || record['status'] == status || status == 'conflict'
          raise Conflict, :terminal_conflict
        end

        raise Invalid, :revision_limit if record['revision'] == MAX_INTEGER

        record['status'] = status.dup
        record['revision'] += 1
        record['evidence'] = evidence
        write(document)
        freeze_tree(record)
      end
    end

    # Acknowledged presence messages and explicitly expired participant leases
    # are disposable local history.
    # Their server events remain immutable, so replaying an old nonce cannot
    # renew readiness or a lease. Unknown writes, conflicts, creation intents,
    # results and other user operations must retain their recovery evidence.
    def trim_confirmed_presence
      access do
        document = read
        eligible = document['operations'].select do |record|
          next false unless %w[confirmed outside_window].include?(record['status']) && record['kind'] == 'plan_document'
          value = StrictJson.parse(record['values']['document_json'], max_nesting: 12)
          (record['status']=='confirmed' && value['kind']=='tournament-shared-readiness-v1') || value['kind']=='tournament-participant-lease-v1'
        end
        discarded = eligible.first([eligible.size - 128, 0].max).map { |record| record['id'] }
        unless discarded.empty?
          document['operations'].reject! { |record| discarded.include?(record['id']) }
          write(document)
        end
        discarded.size
      end
    end

    private

    def verify_json_parser
      JSON.parse('{"key":0,"key":1}', allow_duplicate_key: false, create_additions: false)
    rescue JSON::ParserError
      true
    rescue ArgumentError => error
      raise unless error.message.match?(/unknown keyword.*allow_duplicate_key/)
      raise Error, :incompatible_runtime
    else
      # Starsze JSON mogą zignorować opcję; object_class#[]= nie wykrywa
      # duplikatów w JSON 2.18. Nie zapisujemy wtedy żadnego pliku.
      raise Error, :incompatible_runtime
    end

    def validate_intent(kind, intent_id)
      raise Invalid, :invalid_kind unless TABLES.key?(kind)
      raise Invalid, :invalid_intent unless bounded_text?(intent_id, 256)
    end

    def key?(value)
      text?(value) && value.match?(/\A[A-Za-z0-9_-]{1,64}\z/)
    end

    def integer?(value, minimum = 0)
      value.is_a?(Integer) && value.between?(minimum, MAX_INTEGER)
    end

    def validate_values(kind, values)
      limit = kind == 'plan_document' ? MAX_PLAN_PAYLOAD_BYTES : MAX_PAYLOAD_BYTES
      validate_json(values, limit, :payload_too_large)
      if kind == 'plan_document'
        fields = %w[tournament_id operation_key kind publication_digest roster_generation document_json]
        unless values.is_a?(Hash) && values.keys.sort == fields.sort && values['kind'] == kind &&
            integer?(values['tournament_id'], 1) && text?(values['document_json']) && values['document_json'].bytesize <= ServerPlanDocument::MAX_BYTES
          raise Invalid, :invalid_values
        end
        document = StrictJson.parse(values['document_json'], max_nesting: 12)
        ServerPlanDocument.encode(document, anchor: values.slice('tournament_id', 'operation_key', 'publication_digest', 'roster_generation'))
        return
      end
      fields = kind == 'publication' ? PUBLICATION_FIELDS : %w[tournament_id operation_key kind]
      fields += ['account'] if %w[removal invitation invite_declined].include?(kind)
      fields += %w[account partner pairing_generation] if kind == 'pairing'
      fields += ['publication_generation'] if %w[amendment cancellation].include?(kind)
      fields += ['amendment_json'] if kind == 'amendment'
      unless values.is_a?(Hash) && values.keys.all? { |key| key.is_a?(String) } && values.keys.sort == fields.sort
        raise Invalid, :invalid_values
      end
      if kind != 'publication'
        unless integer?(values['tournament_id'], 1) && key?(values['operation_key']) && values['kind'] == kind
          raise Invalid, :invalid_values
        end
        if kind == 'removal'
          raise Invalid, :invalid_values unless text?(values['account']) && values['account'] == values['account'].downcase
        end
        if %w[invitation invite_declined].include?(kind)
          raise Invalid, :invalid_values unless owner?(values['account'])
        end
        if kind == 'pairing'
          unless owner?(values['account']) && values['account'] == values['account'].downcase &&
              (values['partner'].nil? || (owner?(values['partner']) && values['partner'] == values['partner'].downcase)) && key?(values['pairing_generation'])
            raise Invalid, :invalid_values
          end
        end
        if %w[amendment cancellation].include?(kind)
          raise Invalid, :invalid_values unless key?(values['publication_generation'])
          if kind == 'amendment'
            raise Invalid, :invalid_values unless text?(values['amendment_json'])
            parsed = JSON.parse(values['amendment_json'], allow_duplicate_key: false, max_nesting: 12)
            raise Invalid, :invalid_values unless parsed.is_a?(Hash) && parsed.keys.sort == PUBLICATION_FIELDS.sort
          end
        end
      else
        unless key?(values['publication_key']) && [1,2].any?{|version|values['schema_version'].eql?(version)} &&
            %w[title game rules timezone settings_json schedule_json].all? { |key| text?(values[key]) } &&
            %w[registration_opens_at registration_closes_at].all? { |key| integer?(values[key]) }
          raise Invalid, :invalid_values
        end
        %w[settings_json schedule_json].each do |key|
          parsed = JSON.parse(values[key], allow_duplicate_key: false, create_additions: false, max_nesting: 16)
          raise Invalid, :invalid_values unless parsed.is_a?(Hash)
          validate_json(parsed, MAX_PAYLOAD_BYTES, :payload_too_large)
        end
      end
    rescue JSON::ParserError, Publication::Invalid
      raise Invalid, :invalid_values
    end

    def validate_json(value, limit, size_code)
      validate_json_value(value, 0, [0, 0], {}, limit, size_code)
      raise Invalid, size_code if JSON.generate(value).bytesize > limit
    end

    def validate_json_value(value, depth, budget, ancestors, limit, size_code)
      budget[0] += 1
      raise Invalid, :invalid_values if budget[0] > MAX_NODES
      case value
      when Hash, Array
        if depth >= MAX_DEPTH || value.size > MAX_NODES || ancestors.key?(value.object_id)
          raise Invalid, :invalid_values
        end
        ancestors[value.object_id] = true
        if value.is_a?(Hash)
          value.each do |key, child|
            raise Invalid, :invalid_values unless text?(key) && !key.start_with?('__')
            validate_json_value(key, depth + 1, budget, ancestors, limit, size_code)
            validate_json_value(child, depth + 1, budget, ancestors, limit, size_code)
          end
        else
          value.each { |child| validate_json_value(child, depth + 1, budget, ancestors, limit, size_code) }
        end
        ancestors.delete(value.object_id)
      when String
        raise Invalid, :invalid_values unless text?(value)
        budget[1] += value.bytesize
        raise Invalid, size_code if budget[1] > limit
      when Integer
        raise Invalid, :invalid_values unless integer?(value, -MAX_INTEGER - 1)
      when Float
        raise Invalid, :invalid_values unless value.finite?
      when NilClass, TrueClass, FalseClass
        nil
      else
        raise Invalid, :invalid_values
      end
    end

    def text?(value)
      value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? &&
        (value.encoding == Encoding::UTF_8 || value.ascii_only?)
    end

    def bounded_text?(value, bytes)
      text?(value) && value.bytesize.between?(1, bytes) && !value.match?(/[[:cntrl:]\u2028\u2029]/)
    end

    def owner?(value)
      bounded_text?(value, 256) && value.length <= 64 && !value.match?(/\A[[:space:]]|[[:space:]]\z/)
    end

    def freeze_tree(value)
      value.each { |key, child| freeze_tree(key); freeze_tree(child) } if value.is_a?(Hash)
      value.each { |child| freeze_tree(child) } if value.is_a?(Array)
      value.freeze
    end

    def resolve_directory(directory)
      unless bounded_text?(directory, 4096) && directory.match?(/[^[:space:]]/)
        raise Invalid, :invalid_directory
      end
      path = directory.tr('\\', '/')
      if path.start_with?('//') || path.match?(/\A[A-Za-z]:(?!\/)/)
        raise Invalid, :invalid_directory
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
        raise Invalid, :invalid_directory if stat && !stat.directory?
        raise Invalid, :invalid_directory if !stat && !allow_missing
        parent = File.dirname(path)
        break if parent == path
        path = parent
      end
    end

    def check_paths
      check_directory_chain
      [@path, @path + '.lock'].each do |path|
        stat = path_stat(path)
        raise Error, :unsafe_path if stat && (stat.symlink? || !stat.file? || stat.nlink > 1)
      end
    end

    def access
      @mutex.synchronize do
        check_paths
        File.open(LocalFilesystem.native(@path + '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          raise IOError, 'Nie uzyskano blokady dziennika' unless lock.flock(File::LOCK_EX)
          begin
            check_paths
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end
    rescue SystemCallError, IOError
      raise Error, :journal_io_error
    end

    def validate_document(document)
      unless document.is_a?(Hash) && document.keys.sort == %w[backend_identity operations owner schema_version]
        raise Corrupt, :corrupt_journal
      end
      raise Corrupt, :incompatible_schema unless document['schema_version'].eql?(1)
      unless document['owner'] == @owner && document['backend_identity'] == @backend_identity && document['operations'].is_a?(Array)
        raise Corrupt, :corrupt_journal
      end
      raise Corrupt, :operation_limit if document['operations'].length > MAX_OPERATIONS
      ids, intents = {}, {}
      document['operations'].each do |record|
        validate_record(record)
        id, intent = record['id'], [record['kind'], record['intent_id']]
        raise Corrupt, :corrupt_journal if ids.key?(id) || intents.key?(intent)
        ids[id] = intents[intent] = true
      end
      document
    end

    def validate_record(record)
      unless record.is_a?(Hash) && record.keys.sort == %w[evidence id intent_id kind revision status table_name values] &&
          text?(record['id']) && record['id'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/) &&
          integer?(record['revision'], 1)
        raise Corrupt, :corrupt_journal
      end
      validate_intent(record['kind'], record['intent_id'])
      raise Corrupt, :corrupt_journal unless record['table_name'] == TABLES[record['kind']]
      validate_values(record['kind'], record['values'])
      validate_json(record['evidence'], MAX_EVIDENCE_BYTES, :evidence_too_large)
      valid = case record['status']
      when 'prepared' then record['revision'] == 1 && record['evidence'].nil?
      when 'attempted' then record['revision'] == 2 && record['evidence'].nil?
      when 'confirmed', 'outside_window', 'conflict' then record['revision'] >= 2 && record['evidence'].is_a?(Hash)
      else false
      end
      raise Corrupt, :corrupt_journal unless valid
    rescue Invalid
      raise Corrupt, :corrupt_journal
    end

    def read
      begin
        payload = File.binread(LocalFilesystem.native(@path), MAX_FILE_BYTES + 1) || ''
      rescue Errno::ENOENT
        return {'schema_version' => 1, 'owner' => @owner, 'backend_identity' => @backend_identity, 'operations' => []}
      end
      raise Corrupt, :file_limit if payload.bytesize > MAX_FILE_BYTES
      unless payload.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise Corrupt, :corrupt_journal
      end
      validate_document(JSON.parse(payload, create_additions: false, allow_duplicate_key: false, max_nesting: MAX_DEPTH + 4))
    rescue JSON::ParserError
      raise Corrupt, :corrupt_journal
    end

    def write(document)
      validate_document(document)
      payload = JSON.generate(document)
      raise Invalid, :file_limit if payload.bytesize > MAX_FILE_BYTES
      temporary = "#{@path}.tmp-#{SecureRandom.hex(12)}"
      # The stable journal and lock can fit Windows MAX_PATH while appending
      # a random suffix does not. Keep the atomic temporary in the same directory.
      if temporary.bytesize >= 260
        temporary = File.join(@directory, ".journal-#{SecureRandom.hex(12)}.tmp")
      end
      created = false
      begin
        File.open(LocalFilesystem.native(temporary), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          created = true
          file.binmode
          raise IOError, 'Niepełny zapis dziennika' unless file.write(payload) == payload.bytesize
          file.flush
          file.fsync
        end
        check_paths
        retries = 0
        begin
          File.rename(LocalFilesystem.native(temporary), LocalFilesystem.native(@path))
        rescue Errno::EACCES
          # Windows readers may briefly deny replacement. Retry only this same
          # atomic rename under the journal lock, never the operation or its write.
          raise unless File::ALT_SEPARATOR == '\\' && retries < 4 && File.exist?(LocalFilesystem.native(temporary))
          retries += 1
          sleep(0.025)
          check_paths
          retry
        end
      ensure
        File.delete(LocalFilesystem.native(temporary)) if created && File.exist?(LocalFilesystem.native(temporary))
      end
    end
  end
end
