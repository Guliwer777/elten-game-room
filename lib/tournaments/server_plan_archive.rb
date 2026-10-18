# encoding: UTF-8
require_relative 'operation_journal'
require_relative 'server_plan_document'
require_relative 'server_document_rows'
require_relative 'server_read_scope'

module GameRoomTournaments
  # Durable, idempotent document transport. Call on a Tasks worker. The supplied verifier
  # must check current publication/roster authorization and candidate semantics.
  # This archive never seals a roster or grants permission to start a game.
  class ServerPlanArchive
    class ContextChanged < StandardError; end
    class Unconfirmed < StandardError; end
    ANCHOR_FIELDS = %w[operation_key tournament_id publication_digest roster_generation].freeze

    def initialize(table:, journal:, user:, verify:, refresh: nil, document_digest: nil)
      @table, @journal, @user, @verify = table, journal, user, verify
      @refresh = refresh
      ServerPlanDocument.digest!(document_digest) if document_digest
      @document_digest = document_digest&.dup&.freeze
      @owner = journal.owner
      @changed = false
      account!
    end

    def publish(intent_id:, document:, anchor:)
      account!
      frozen_document = Publication::Data.freeze_tree(ServerPlanDocument.copy_document(document))
      frozen_anchor = Publication::Data.freeze_tree(Publication::Data.copy(anchor))
      verify!(frozen_document, frozen_anchor)
      rows = ServerPlanDocument.encode(frozen_document, anchor: frozen_anchor)
      json = JSON.generate(frozen_document)
      raise Publication::Invalid, :plan_journal_limit if json.bytesize > ServerPlanDocument::MAX_BYTES
      values = frozen_anchor.merge('kind' => 'plan_document', 'document_json' => json)
      account!
      record = @journal.prepare(kind: 'plan_document', intent_id: intent_id, values: values)
      account!
      # prepare preserves the original key on a repeated intent.
      rows = ServerPlanDocument.encode(frozen_document, anchor: record['values'].slice(*ANCHOR_FIELDS))
      return resume(record['id']) unless record['status'] == 'prepared'
      account!
      claimed = @journal.claim(record['id'])
      return resume(record['id']) unless claimed
      write_missing(rows, frozen_document)
      reconcile(record['id'])
    end

    # Only document parts are resumable. This never retries creation of a native
    # table or a game. The original intent, author and every part remain fixed.
    def resume(id)
      account!
      record = @journal.fetch(id)
      raise OperationJournal::Invalid, :missing_plan_operation unless record && record['kind'] == 'plan_document'
      return reconcile(id) if record['status'] == 'confirmed'
      raise Unconfirmed, 'Conflicting operation' unless %w[prepared attempted].include?(record['status'])
      document = StrictJson.parse(record['values']['document_json'], max_nesting: 12)
      anchor = record['values'].slice(*ANCHOR_FIELDS)
      if record['status'] == 'prepared'
        account!
        @journal.claim(id)
        account!
      end
      write_missing(ServerPlanDocument.encode(document, anchor: anchor), document)
      reconcile(id)
    end

    def write_missing(rows, document)
      anchor = rows.first.slice(*ANCHOR_FIELDS)
      stored = read_rows(anchor)
      existing = stored.empty? ? [] : ServerPlanDocument.canonical_rows(stored, anchor: anchor, author: @owner)
      unless existing.all? { |part| rows[part['part_index']] == part.slice(*ServerPlanDocument::FIELDS) }
        raise Unconfirmed, 'Stored document differs from intent'
      end
      indexes = existing.map { |row| row['part_index'] }
      # Revalidate the whole immutable document before the batch and after
      # readback. Individual chunks confer no permission and are unusable until
      # complete; account identity is still checked around every SDK write.
      verify!(document, anchor)
      rows.each do |row|
        next if indexes.include?(row['part_index'])
        account!
        @table.insert(row)
        account!
      end
    end

    def reconcile(id)
      account!
      record = @journal.fetch(id)
      raise OperationJournal::Invalid, :missing_plan_operation unless record && record['kind'] == 'plan_document'
      values = record['values']
      document = StrictJson.parse(values['document_json'], max_nesting: 12)
      anchor = Publication::Data.freeze_tree(values.slice(*ANCHOR_FIELDS))
      rows = read_rows(anchor)
      account!
      # A temporarily empty or incomplete read does not establish absence.
      raise Unconfirmed, 'Plan document is not fully visible' if rows.empty?
      begin
        decoded = ServerPlanDocument.decode(rows, anchor: anchor, author: @owner)
        rows = ServerPlanDocument.canonical_rows(rows, anchor: anchor, author: @owner)
      rescue Publication::Invalid => error
        raise Unconfirmed, error.code.to_s
      end
      raise Unconfirmed, 'Stored document differs from intent' unless decoded.eql?(document)
      verify!(decoded, anchor)
      evidence = {'document_digest' => rows.first.fetch('document_digest'), 'row_ids' => rows.map { |r| r.fetch('__id') }.sort}
      account!
      if record['status'] == 'confirmed'
        raise Unconfirmed, 'Stored evidence changed' unless record['evidence'].eql?(evidence)
        return record
      end
      result = @journal.resolve(record['id'], status: 'confirmed', evidence: evidence, expected_revision: record['revision'])
      account!
      result
    end

    private

    private :write_missing

    def read_rows(anchor)
      where = {'operation_key' => anchor['operation_key']}
      # Opt-in immutable attempts share a discovery key, but never parts or
      # journal intents. All existing single-document callers remain strict.
      where['document_digest'] = @document_digest if @document_digest
      ServerDocumentRows.read(@table, where: where, guard: method(:account!), author: @owner)
    end

    def account!
      value = Publication::Data.account(@user.call).downcase
      @changed = true unless value == @owner
      raise ContextChanged, 'Account changed' if @changed
    rescue Publication::Invalid
      @changed = true
      raise ContextChanged, 'Account unavailable'
    end

    def verify!(document, anchor)
      account!
      document = Publication::Data.freeze_tree(ServerPlanDocument.copy_document(document))
      anchor = Publication::Data.freeze_tree(Publication::Data.copy(anchor))
      if @document_digest && Digest::SHA256.hexdigest(JSON.generate(document)) != @document_digest
        raise Publication::Invalid, :plan_document_digest_mismatch
      end
      permitted = if @refresh
        @refresh.call
        @verify.call(document,anchor)
      else
        ServerReadScope.verify { @verify.call(document,anchor) }
      end
      raise Publication::Invalid, :plan_not_authorized unless permitted == true
      account!
    end
  end
end
