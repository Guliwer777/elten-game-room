require_relative 'knockout_schedule'
require_relative 'local_knockout_plan'

module GameRoomTournaments
  # Routes a reviewed phase through the existing family compiler, validation,
  # acceptance and request producers. Execution retains the original store and
  # busy map; only accepted plan records have a separate durable namespace.
  module LocalKnockoutExecutionPlans
    def initialize(**options)
      super
      root = File.dirname(@storage.path)
      @phase_execution_directory = phase_team? ? File.join(root, 'execution-ft2-v1') : File.join(root, 'individual-v1', 'execution-v1')
      @phase_storage = LocalExecutionPlanStorage.new(directory: File.join(root, 'knockout-execution-v1'), guard: method(:guard!))
    end

    def knockout_execution_preview(parent_intent:, base_seats: nil)
      parent = current(intent_id: parent_intent)
      raise Publication::Invalid, :missing_plan unless parent
      approval = phase_approval_store.readback(parent_intent: parent['preview']['intent_id'])
      raise Publication::Invalid, :phase_approval_required unless approval
      phase_preview(parent: parent, approval: approval, base_seats: base_seats, actor: @actor)
    end

    # Used while the approval store itself is locked. The parent phase's
    # embedded approval proof is checked by readback; revalidate its original
    # publication/roster without trying to lock the same approval file again.
    def current_for_phase_approval(intent_id:)
      previous = @checking_phase_approval_parent
      @checking_phase_approval_parent = true
      begin
        current(intent_id: intent_id)
      ensure
        @checking_phase_approval_parent = previous
      end
    end

    def readback(intent_id:)
      cached = @phase_validation_records&.[](intent_id) || @phase_accept_parents&.[](intent_id)
      return detached(cached) if cached
      prior = super
      return prior if prior || !phase_intent?(intent_id)
      @phase_storage.access(validate: method(:validate_document!)) do |document|
        link = document && document['intents'].find { |row| row['intent_id'] == intent_id }
        record = link && document['records'].find { |row| row['preview']['intent_id'] == link['record_intent_id'] }
        record && detached(record)
      end
    end

    def accept(preview:)
      return super unless phase?(preview)
      previous = @phase_accept_parents
      parents = {}
      id = preview['source']['knockout_parent_intent']
      (LocalExecutionPlanStorage::MAX_RECORDS + 1).times do
        parent = current(intent_id: id)
        raise Publication::Invalid, :missing_plan unless parent
        raise Publication::Invalid, :invalid_phase_parent if parents.key?(id)
        parents[id] = parent
        break unless phase?(parent['preview'])
        id = parent['preview']['source']['knockout_parent_intent']
      end
      raise Publication::Invalid, :invalid_phase_parent if phase?(parents.values.last['preview'])
      # Approval history may also refer to another tournament's earlier phase.
      # Preload all immutable records before taking the phase write lock.
      @phase_accept_parents = accepted_records.to_h { |r| [r['preview']['intent_id'], r] }.merge(parents).freeze
      super
    ensure
      @phase_accept_parents = previous if phase?(preview)
    end

    def accepted_records(catalog: false)
      prior = super
      extra = @phase_storage.access(validate: method(:validate_document!), read_failure: catalog ? self.class::CatalogReadError : nil) do |document|
        detached(document ? document.fetch('records') : [])
      end
      detached(prior + extra)
    end

    private
    def phase_team?; defined?(LocalFixedTeamPlanBackend) && instance_of?(LocalFixedTeamPlanBackend); end
    def phase_intent?(id); id.is_a?(String) && id.match?(/\Aknockout-execution-v1:[0-9a-f]{64}\z/); end
    def phase?(shown); shown.is_a?(Hash) && shown['source'].is_a?(Hash) && shown['source'].key?('knockout_parent_intent'); end
    def plan_storage(shown); phase?(shown) ? @phase_storage : @storage; end
    def plan_storage_for_id(_id); @storage; end

    def phase_approval_store
      LocalKnockoutPlan.new(directory: @phase_execution_directory, identity: identity, actor: @actor,
        guard: method(:guard!), parent_reader: ->(id, fresh) { fresh ? current_for_phase_approval(intent_id: id) : readback(intent_id: id) })
    end

    def phase_preview(parent:, approval:, base_seats:, actor:)
      raise Publication::Invalid, :invalid_phase_parent unless %w[groups_knockout knockout].include?(parent['preview']['source']['candidate']['format'])
      candidate = KnockoutSchedule.candidate(parent: parent, approval: approval)
      require_competitive_roster!(candidate) if !phase_team? && parent['preview'].key?('result_policy')
      source = parent['preview']['source'].merge('candidate' => candidate,
        'knockout_parent_intent' => parent['preview']['intent_id'], 'knockout_approval' => approval)
      unless base_seats
        units = phase_team? && candidate['membership']['units'].to_h { |unit| [unit['unit_id'], unit['accounts']] }
        base_seats = candidate['matches'].select { |match| match['leg'] == 1 }.to_h do |match|
          seats = if units
            sides = match['unit_ids'].map { |id| units.fetch(id) }
            candidate['team_template'].each_with_index.map { |side, seat| sides[side][candidate['team_template'].take(seat).count(side)] }
          else
            match['players']
          end
          [match['match_id'], seats]
        end
      end
      assignments = phase_assignments(candidate, base_seats, members_for(source))
      body = {'version' => 1, 'identity' => identity, 'actor' => actor,
        'intent_id' => 'knockout-execution-v1:' + approval['preview']['digest'], 'source' => source,
        'base_seats' => base_seats, 'assignments' => assignments, 'windows' => windows_for(candidate)}
      body.merge!('membership' => candidate['membership'], 'team_template' => candidate['team_template']) if phase_team?
      body['result_policy'] = parent['preview']['result_policy'] if parent['preview'].key?('result_policy')
      detached(body.merge('digest' => digest(semantic(body))))
    end

    def validate_preview!(shown)
      return super unless phase?(shown)
      id = shown['source']['knockout_parent_intent']
      parent = readback(intent_id: id)
      raise Publication::Invalid, :missing_plan unless parent
      approval = shown['source']['knockout_approval']
      CoordinationRequest.fields!(approval, %w[preview approval dispatch_allowed])
      proof = KnockoutPhase.build(record: parent, receipts: approval['preview']['receipts'], seeds: approval['preview']['plan']['seeds'])
      unless proof.eql?(approval['preview']) && approval['dispatch_allowed'].equal?(false) &&
          approval['approval'].eql?({'actor' => parent['preview']['source']['candidate']['publication_ref']['author'],
            'digest' => proof['digest'], 'policy_ref' => 'local-knockout-pairings-approval-v1'})
        raise Publication::Invalid, :phase_changed
      end
      rebuilt = phase_preview(parent: parent, approval: approval, base_seats: shown['base_seats'], actor: shown['actor'])
      raise Publication::Invalid, :invalid_preview unless rebuilt.eql?(shown)
      guard!
    end

    def require_source!(shown)
      return super unless phase?(shown)
      parent = current(intent_id: shown['source']['knockout_parent_intent'])
      raise Publication::Invalid, :missing_plan unless parent
      # This does not authorize a changed roster or reinterpret a group plan.
      expected = phase_preview(parent: parent, approval: shown['source']['knockout_approval'],
        base_seats: shown['base_seats'], actor: shown['actor'])
      raise Publication::Invalid, :source_changed unless semantic(expected).eql?(semantic(shown))
      unless @checking_phase_approval_parent
        approved = phase_approval_store.readback(parent_intent: parent['preview']['intent_id'])
        raise Publication::Invalid, :phase_approval_required unless approved.eql?(shown['source']['knockout_approval'])
      end
    end

    # One locked phase document is an immutable ancestry graph. Resolve its
    # earlier parents in RAM instead of re-entering its file lock. Every record
    # still passes the ordinary compiler/UUID/contract validation in super.
    def validate_document!(document)
      return super unless document.is_a?(Hash) && document['records'].is_a?(Array) && document['records'].any? { |r| phase?(r['preview']) }
      previous = @phase_validation_records
      if @phase_accept_parents
        document['records'].each do |record|
          old = @phase_accept_parents[record['preview']['intent_id']]
          raise Publication::Invalid, :source_changed if old && !old.eql?(record)
        end
      end
      @phase_validation_records = document['records'].to_h { |r| [r['preview']['intent_id'], r] }
      begin
        super
      ensure
        @phase_validation_records = previous
      end
    end

    def members_for(source)
      members = super
      return members unless source.key?('knockout_parent_intent')
      members.select { |person| source['candidate']['roster'].include?(person['account']) }
    end

    def execution_content(shown)
      content = super
      return content unless shown['source']['candidate'].key?('knockout')
      content['source']['knockout'] = shown['source']['candidate']['knockout']
      content
    end

    def assignment_key(shown)
      key = super
      phase?(shown) ? key + [shown['source']['candidate']['schedule_id']] : key
    end
  end
end
