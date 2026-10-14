# encoding: UTF-8
require_relative 'operation_journal'
require_relative 'server_plan_document'

module GameRoomTournaments
  # Durable one-attempt transport. Call on a Tasks worker. The supplied verifier
  # must check current publication/roster authorization and candidate semantics.
  # This archive never seals a roster or grants permission to start a game.
  class ServerPlanArchive
    class ContextChanged < StandardError; end
    class Unconfirmed < StandardError; end
    ANCHOR_FIELDS = %w[operation_key tournament_id publication_digest roster_generation].freeze

    def initialize(table:, journal:, user:, verify:)
      @table, @journal, @user, @verify = table, journal, user, verify
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
      raise Publication::Invalid, :plan_journal_limit if json.bytesize > 120_000
      values = frozen_anchor.merge('kind' => 'plan_document', 'document_json' => json)
      account!
      record = @journal.prepare(kind: 'plan_document', intent_id: intent_id, values: values)
      account!
      # prepare preserves the original key on a repeated intent.
      rows = ServerPlanDocument.encode(frozen_document, anchor: record['values'].slice(*ANCHOR_FIELDS))
      return reconcile(record['id']) unless record['status'] == 'prepared'
      verify!(frozen_document, record['values'].slice(*ANCHOR_FIELDS))
      account!
      claimed = @journal.claim(record['id'])
      return reconcile(record['id']) unless claimed
      # All exceptions leave the durable claim in attempted state. No retry,
      # including after a lost claim acknowledgement or partial row insertion.
      rows.each do |row|
        verify!(frozen_document, row.slice(*ANCHOR_FIELDS))
        account!
        @table.insert(row)
        account!
      end
      reconcile(record['id'])
    end

    def reconcile(id)
      account!
      record = @journal.fetch(id)
      raise OperationJournal::Invalid, :missing_plan_operation unless record && record['kind'] == 'plan_document'
      values = record['values']
      document = StrictJson.parse(values['document_json'], max_nesting: 12)
      anchor = Publication::Data.freeze_tree(values.slice(*ANCHOR_FIELDS))
      verify!(document, anchor)
      rows = @table.select(where: {'operation_key' => anchor['operation_key']}, limit: ServerPlanDocument::MAX_PARTS + 2).to_a
      account!
      # A temporarily empty or incomplete read does not establish absence.
      raise Unconfirmed, 'Plan document is not fully visible' if rows.empty?
      begin
        decoded = ServerPlanDocument.decode(rows, anchor: anchor, author: @owner)
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
      raise Publication::Invalid, :plan_not_authorized unless @verify.call(document, anchor) == true
      account!
    end
  end
end
