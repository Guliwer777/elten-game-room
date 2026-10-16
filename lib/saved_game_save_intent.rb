# encoding: UTF-8
require_relative 'tournaments/operation_journal'
require_relative 'tournaments/strict_json'

# Prywatne metadane operacji, NIE kopia archiwum ani dziennik publikacji.
# Współdzieli wyłącznie walidację JSON oraz flock/atomic write z istniejącym
# magazynem. Odczyt nie migruje pliku. Callback konta jest lokalny, nie zapisany.
class GameRoomSavedGameSaveIntent < GameRoomTournaments::OperationJournal
  class Pending < StandardError; end
  class ContextChanged < StandardError; end
  class ClosePending < StandardError
    attr_reader :id, :code
    def initialize(id)
      @id, @code = id, :close_pending
      super('Archive confirmed; conditional close of the original session is unavailable (close_pending)')
    end
  end
  class Uncertain < IOError
    attr_reader :id, :readback_error
    def initialize(id, readback_error = nil)
      @id, @readback_error = id, readback_error
      super('Nie potwierdzono archiwum; wymagane jawne uzgodnienie')
    end
  end
  STATUSES = %w[prepared attempted uncertain readback_confirmed definitive_preupload].freeze
  VALUES = %w[archive_id checksum manifest sha256 source boundary prefix].freeze

  def initialize(directory:, owner:, backend_identity:, account:)
    raise Invalid, :invalid_account_reader unless account.respond_to?(:call)
    @account = account
    super(directory: directory, owner: owner, backend_identity: backend_identity)
    @path = @path.sub('tournament-operations-', 'saved-game-intents-').freeze
    check_paths
  end

  def check_context!(owner: @owner)
    current = @account.call
    unless owner.is_a?(String) && current.is_a?(String) &&
        owner.downcase == @owner && current.downcase == @owner && !@context_changed
      @context_changed = true
      raise ContextChanged, 'Zmieniono konto trwałego zapisu'
    end
    true
  end

  # Check even after an exception; preserve that exact exception and its cause.
  # Do not use $!: it can refer to an enclosing, already handled upload error.
  def guard(owner: @owner)
    check_context!(owner: owner)
    completed = false
    begin
      result = yield
      completed = true
      result
    ensure
      if completed
        check_context!(owner: owner)
      else
        begin
          check_context!(owner: owner)
        rescue ContextChanged
          # The latch remains set; the original I/O/program failure wins.
        end
      end
    end
  end

  def list
    check_context!
    super
  end

  # Lokalna wyłączność całego SaveGame, od odczytu intencji do rollbacku.
  # Osobny flock działa także między obiektami/procesami wspólnego katalogu;
  # LOCK_NB odrzuca reentry bez czekania na siebie. Nie jest serwerowym CAS.
  # Blokada dziennika pozostaje krótka: drugi czytnik nadal może uzgodnić zapis.
  def with_save_attempt
    check_context!
    check_save_lock_path
    File.open(@path + '.save.lock', File::RDWR | File::CREAT, 0o600) do |lock|
      raise Pending, 'Trwa już próba zapisu; wymagane uzgodnienie' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      begin
        check_save_lock_path
        check_context!
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  def for_source(table_id:, session_id:)
    list.find { |record| record.dig('values','source','table_id') == table_id && record.dig('values','source','session_id') == session_id }
  end

  def prepare_archive(row:, source:, boundary:, manifest:)
    check_context!(owner: row['owner'])
    values = {'archive_id'=>row['id'], 'checksum'=>row['checksum'], 'manifest'=>manifest,
      'sha256'=>Digest::SHA256.hexdigest(JSON.generate(row)), 'source'=>source,
      'boundary'=>boundary, 'prefix'=>self.class.prefix(row['events'])}
    validate_values_document(values)
    access do
      document = read
      previous = document['operations'].find { |r| r.dig('values','source') == source }
      raise Pending, 'Istnieje już intencja; wymagane uzgodnienie' if previous
      raise Invalid, :operation_limit if document['operations'].size >= MAX_OPERATIONS
      record = {'id'=>row['id'], 'revision'=>1, 'status'=>'prepared', 'values'=>values, 'closed'=>false}
      document['operations'] << record
      write(document)
      freeze_tree(record)
    end
  end

  def claim(id)
    transition(id, from: %w[prepared], to: 'attempted')
  end

  def uncertain(id); transition(id, from: %w[attempted uncertain], to: 'uncertain'); end
  def reject_before_upload(id); transition(id, from: %w[prepared], to: 'definitive_preupload'); end
  def confirm(id); transition(id, from: %w[attempted uncertain readback_confirmed], to: 'readback_confirmed'); end
  def closed(id); transition(id, from: %w[readback_confirmed], to: 'readback_confirmed', closed: true); end

  def self.prefix(events)
    {'count'=>events.length, 'last_id'=>events.last ? events.last.fetch('id') : 0,
      'sha256'=>Digest::SHA256.hexdigest(JSON.generate(events))}
  end

  private

  def check_save_lock_path
    check_paths
    stat = path_stat(@path + '.save.lock')
    raise Error, :unsafe_path if stat && (stat.symlink? || !stat.file? || stat.nlink > 1)
  end

  def access(&block)
    guard { super(&block) }
  end

  def read
    guard { super }
  end

  def write(document)
    guard { super }
  end

  def transition(id, from:, to:, closed: false)
    check_context!
    access do
      document = read
      record = document['operations'].find { |r| r['id'] == id }
      raise Pending, 'Nie ma prawa do tej operacji' unless record && from.include?(record['status'])
      next freeze_tree(record) if record['status'] == to && (!closed || record['closed'])
      raise Invalid, :revision_limit if record['revision'] == MAX_INTEGER
      record['status'], record['revision'] = to, record['revision'] + 1
      record['closed'] = true if closed
      write(document)
      freeze_tree(record)
    end
  end

  def validate_document(document)
    unless document.is_a?(Hash) && document.keys.sort == %w[backend_identity operations owner schema_version] &&
        document['schema_version'].eql?(1) && document['owner'] == @owner &&
        document['backend_identity'] == @backend_identity && document['operations'].is_a?(Array) &&
        document['operations'].length <= MAX_OPERATIONS
      raise Corrupt, :corrupt_save_intents
    end
    ids, sources = {}, {}
    document['operations'].each do |record|
      validate_record(record)
      source = record['values']['source'].slice('table_id','session_id')
      raise Corrupt, :duplicate_intent if ids[record['id']] || sources[source]
      ids[record['id']] = sources[source] = true
    end
    document
  end

  def validate_record(record)
    unless record.is_a?(Hash) && record.keys.sort == %w[closed id revision status values] &&
        uuid?(record['id']) && integer?(record['revision'],1) && STATUSES.include?(record['status']) &&
        [true,false].include?(record['closed']) && (!record['closed'] || record['status'] == 'readback_confirmed')
      raise Corrupt, :invalid_save_intent
    end
    validate_values_document(record['values'])
    raise Corrupt, :invalid_save_intent unless record['values']['archive_id'] == record['id']
  rescue Invalid
    raise Corrupt, :invalid_save_intent
  end

  def validate_values_document(values)
    validate_json(values, MAX_EVIDENCE_BYTES, :intent_too_large)
    unless values.is_a?(Hash) && values.keys.sort == VALUES.sort && uuid?(values['archive_id']) &&
        hash?(values['checksum']) && hash?(values['sha256']) && bounded_text?(values['manifest'],1024)
      raise Invalid, :invalid_save_intent
    end
    meta = GameRoomTournaments::StrictJson.parse(values['manifest'], max_nesting: MAX_DEPTH)
    unless meta.is_a?(Hash) && meta['id'] == values['archive_id'] && meta['sha256'] == values['sha256'] &&
        meta['owner'].is_a?(String) && meta['owner'].downcase == @owner
      raise Invalid, :invalid_manifest
    end
    source, boundary, prefix = values.values_at('source','boundary','prefix')
    unless source.is_a?(Hash) && source.keys.sort == %w[game native_room session_id table_id] &&
        integer?(source['table_id'],1) && integer?(source['session_id'],1) && uuid?(source['native_room']) &&
        bounded_text?(source['game'],64) && source['game'] == meta['game']
      raise Invalid, :invalid_source
    end
    unless boundary.is_a?(Hash) && boundary.keys.sort == %w[created_at message_id sender sequence] &&
        integer?(boundary['sequence'],1) && integer?(boundary['created_at'],1) &&
        bounded_text?(boundary['message_id'],256) && boundary['sender'].is_a?(String) && boundary['sender'].downcase == @owner
      raise Invalid, :invalid_boundary
    end
    unless prefix.is_a?(Hash) && prefix.keys.sort == %w[count last_id sha256] && integer?(prefix['count']) &&
        prefix['count'] <= GameRoomLiveSessionStore::MAX_ARCHIVE_EVENTS && integer?(prefix['last_id']) && hash?(prefix['sha256'])
      raise Invalid, :invalid_prefix
    end
  rescue JSON::ParserError
    raise Invalid, :invalid_manifest
  end

  def uuid?(value)
    text?(value) && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
  end
  def hash?(value); text?(value) && value.match?(/\A[0-9a-f]{64}\z/); end
end
