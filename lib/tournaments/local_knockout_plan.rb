require_relative 'knockout_phase'
require_relative 'local_execution_plan_storage'

module GameRoomTournaments
  # Durable review of pairings, separate from the immutable group plan and
  # execution log. Caller holds the validated execution transaction while
  # comparing fresh results and accepting. No native target is produced here.
  class LocalKnockoutPlan
    Invalid = Publication::Invalid
    class Unconfirmed < IOError
      attr_reader :digest
      def initialize(digest)
        @digest = digest
        super('Knockout pairing acceptance needs readback')
      end
    end
    def initialize(directory:, identity:, actor:, guard:, parent_reader:)
      @identity, @actor, @guard, @parent_reader = identity, actor, guard, parent_reader
      @storage = LocalExecutionPlanStorage.new(directory: File.join(directory, 'knockout-plans-v1'), guard: guard)
    end

    def accept(preview:, current:)
      @guard.call
      shown = KnockoutPhase.frozen_copy(preview)
      KnockoutPhase.shape!(shown)
      raise Invalid, :phase_changed unless shown.eql?(current)
      parent = @parent_reader.call(shown['parent']['intent_id'], true)
      raise Invalid, :missing_plan unless parent
      raise Invalid, :not_author unless parent['preview']['source']['candidate']['publication_ref']['author'] == @actor
      validate_preview!(shown, parent)
      result = nil
      @storage.access(validate: method(:validate_document!)) do |document|
        document ||= {'version' => 1, 'identity' => @identity, 'records' => []}
        prior = document['records'].find { |r| r['preview']['parent']['intent_id'] == shown['parent']['intent_id'] }
        if prior
          raise Invalid, :phase_conflict unless prior['preview'].eql?(shown)
          result = prior
          next
        end
        raise Invalid, :sandbox_limit if document['records'].size >= LocalExecutionPlanStorage::MAX_RECORDS
        result = {'preview' => shown, 'approval' => {'actor' => @actor, 'digest' => shown['digest'],
          'policy_ref' => 'local-knockout-pairings-approval-v1'}, 'dispatch_allowed' => false}
        document['records'] << result
        raise Invalid, :phase_changed unless @parent_reader.call(shown['parent']['intent_id'], true).eql?(parent)
        begin
          @storage.write(document)
        rescue IOError, SystemCallError => error
          raise unless [:replace_attempted, :replaced].include?(@storage.last_write_state)
          raise Unconfirmed.new(shown['digest']), cause: error
        end
      end
      KnockoutPhase.frozen_copy(result)
    end

    def readback(parent_intent:)
      @storage.access(validate: method(:validate_document!)) do |document|
        result = document && document['records'].find { |r| r['preview']['parent']['intent_id'] == parent_intent }
        result && KnockoutPhase.frozen_copy(result)
      end
    end

    private
    def validate_preview!(shown, parent)
      KnockoutPhase.shape!(shown)
      raise Invalid, :missing_plan unless parent
      rebuilt = KnockoutPhase.build(record: parent, receipts: shown.fetch('receipts'), seeds: shown.fetch('plan').fetch('seeds'))
      raise Invalid, :phase_changed unless rebuilt.eql?(shown)
    end

    def validate_document!(document)
      CoordinationRequest.fields!(document, %w[version identity records])
      unless document['version'].eql?(1) && document['identity'] == @identity && document['records'].is_a?(Array) && document['records'].size <= LocalExecutionPlanStorage::MAX_RECORDS
        raise Invalid, :sandbox_corrupt
      end
      seen = []
      document['records'].each do |record|
        CoordinationRequest.fields!(record, %w[preview approval dispatch_allowed])
        shown, approval = record.values_at('preview', 'approval')
        KnockoutPhase.shape!(shown)
        CoordinationRequest.fields!(approval, %w[actor digest policy_ref])
        id = shown.fetch('parent').fetch('intent_id')
        raise Invalid, :sandbox_corrupt if seen.include?(id)
        seen << id
        parent = @parent_reader.call(id, false)
        validate_preview!(shown, parent)
        unless approval.eql?({'actor' => parent['preview']['source']['candidate']['publication_ref']['author'],
            'digest' => shown['digest'], 'policy_ref' => 'local-knockout-pairings-approval-v1'}) && record['dispatch_allowed'].equal?(false)
          raise Invalid, :sandbox_corrupt
        end
      end
    end
  end
end
