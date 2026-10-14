# encoding: UTF-8
require_relative 'server_plan_archive'
require_relative 'tables_gateway'

module GameRoomTournaments
  # Shared observed candidate only, not authoritative execution coordination.
  # The source reader must use this table's backend and fresh complete evidence.
  class ServerScheduleStore
    Data = Publication::Data
    def initialize(table:, journal:, user:, source:, guard: -> { true })
      @table, @journal, @user, @source, @guard = table, journal, user, source, guard
      @owner = journal.owner
      @changed = false
      check!
    end

    def synchronize
      expected, anchor = source!
      rows = read_rows(anchor)
      if rows.empty?
        return response(expected, 'missing') unless expected['publication_ref']['author'] == @owner
        archive.publish(intent_id: intent(anchor), document: expected, anchor: anchor)
        rows = read_rows(anchor)
      end
      # Nonempty partial/conflicting data never give permission for more inserts,
      # even on another computer without this writer's journal.
      document = ServerPlanDocument.decode(rows, anchor: anchor, author: expected['publication_ref']['author'])
      fresh, current = source!
      raise ServerPlanArchive::Unconfirmed, 'Candidate changed' unless current.eql?(anchor) && fresh.eql?(document)
      if expected['publication_ref']['author'] == @owner
        record = @journal.find(kind: 'plan_document', intent_id: intent(anchor))
        check!
        archive.reconcile(record['id']) if record
      end
      response(document, 'confirmed')
    rescue ServerPlanDocument::Invalid => error
      raise ServerPlanArchive::Unconfirmed, error.code.to_s
    end

    def reconcile(id)
      check!
      archive.reconcile(id)
    end

    private

    def intent(anchor)
      'automatic-server-candidate-v1:' + anchor.fetch('operation_key')
    end

    def archive
      ServerPlanArchive.new(table: @table, journal: @journal, user: -> { check!; account! },
        verify: ->(document, retained) { fresh, current = source!; fresh.eql?(document) && current.eql?(retained) && fresh['publication_ref']['author'] == @owner })
    end

    def source!
      check!
      value = @source.call
      check!
      @phase_history=value['phase_history']
      document = ServerPlanDocument.copy_document(value.fetch('candidate').reject { |key, _| key == 'observed_at' })
      unless document['state'] == 'observed_candidate' && document['finality'] == 'unknown' &&
          %w[start_allowed dispatch_allowed finalize_allowed].all? { |key| document[key] == false }
        raise Publication::Invalid, :invalid_plan_document
      end
      anchor = {'operation_key' => Digest::SHA256.hexdigest(JSON.generate(['automatic-server-candidate-v1',
        @journal.backend_identity, value.fetch('tournament_id'), document.fetch('schedule_id')])),
        'tournament_id' => value.fetch('tournament_id'), 'publication_digest' => document.fetch('publication_digest'),
        'roster_generation' => document.fetch('roster_generation')}
      ServerPlanDocument.anchor!(anchor)
      Data.freeze_tree([document, anchor])
    end

    def read_rows(anchor)
      check!
      rows = @table.select(where: {'operation_key' => anchor['operation_key']}, limit: ServerPlanDocument::MAX_PARTS + 2).to_a
      check!
      Data.copy(rows, max_bytes: 524_288, max_nodes: 16_384, max_depth: 8)
    end

    def response(document, storage)
      check!
      value={'candidate'=>document,'storage'=>storage}
      value['phase_history']=@phase_history if @phase_history && !@phase_history.empty?
      Data.freeze_tree(value)
    end

    def account!
      value = Data.account(@user.call)
      @changed = true unless value.downcase == @owner
      raise ServerPlanArchive::ContextChanged, 'Account changed' if @changed
      value
    rescue Publication::Invalid
      @changed = true
      raise ServerPlanArchive::ContextChanged, 'Account unavailable'
    end

    def check!
      account!
      raise TablesGateway::Cancelled, 'View changed' unless @guard.call
      account!
    end
  end
end
