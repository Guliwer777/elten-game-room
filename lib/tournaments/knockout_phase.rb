require_relative 'knockout_round'
require_relative 'knockout_replay'
require_relative 'coordination_request'
require_relative 'local_individual_standings'
require_relative 'local_fixed_team_standings'
require_relative 'group_tiebreak'
require_relative 'knockout_win_series'

module GameRoomTournaments
  # A reviewed round and its exact parent/result lineage. This is not a
  # CoordinationRequest: accepting pairings alone grants no room/Start rights.
  module KnockoutPhase
    Data = Publication::Data
    module_function

    def build(record:, receipts:, seeds: nil)
      intent = record.fetch('preview').fetch('intent_id')
      unless receipts.is_a?(Array) && receipts.size <= 256 &&
          receipts.all? { |r| r.is_a?(Hash) && r['record_intent'] == intent }
        raise Publication::Invalid, :invalid_phase_results
      end
      individual = record.fetch('evidence').fetch('version') == 1
      summary_class = individual ? LocalIndividualStandings : LocalFixedTeamStandings
      summary = summary_class.build(record: record, executions: receipts.map { |r| {'record_intent' => intent, 'result' => r} })
      count = individual ? record['preview']['source']['candidate']['players_per_match'] : 2
      candidate = record['preview']['source']['candidate']
      if candidate.dig('knockout', 'qualification')
        raise Publication::Invalid, :group_stage_incomplete unless summary['complete']
        progress = summary.fetch('qualification_progress')
        if progress['state'] == 'ready_knockout'
          view = progress.fetch('projection')
          ordered = view.fetch('cross_seeding').fetch('seeds')
          raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != ordered
          plan = KnockoutRound.from_qualification(qualified: view['qualified'], seeds: ordered, players_per_match: count)
        else
          plan = GroupTiebreak.build(snapshot: progress['snapshot'], attempt: candidate['knockout']['qualification']['attempt'] + 1)
          raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != plan['seeds']
        end
      elsif candidate['format'] == 'knockout'
        raise Publication::Invalid, :tournament_completed if summary['knockout_state'] == 'completed'
        unless summary['complete'] && %w[ready_next_round tie_requires_resolution awaiting_series].include?(summary['knockout_state'])
          raise Publication::Invalid, :knockout_round_incomplete
        end
        if summary['knockout_state']=='awaiting_series'
          series=candidate['knockout']['series']
          plan=KnockoutWinSeries.build(base:series['base_plan'],history:summary.fetch('series_history'),target:series['target'],attempt:series['attempt']+1)
          raise Publication::Invalid,:invalid_qualification_seeding if seeds && seeds!=plan['seeds']
        elsif summary['knockout_state'] == 'tie_requires_resolution'
          ordered = candidate['knockout']['seeds']
          raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != ordered
          attempt = candidate['knockout'].dig('replay', 'attempt').to_i + 1
          plan = KnockoutReplay.build(base: summary['knockout_progress']['plan'],
            resolved: summary['knockout_resolved_results'], attempt: attempt)
        else
        ordered = summary.fetch('knockout_progress').fetch('next_seeds')
        raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != ordered
        plan = KnockoutRound.build(seeds: ordered, players_per_match: count, round_number: candidate['knockout']['round'] + 1)
        end
      else
        if summary['complete'] && %w[tie_requires_resolution seeding_tie_requires_resolution].include?(summary['group_state']) &&
            GroupAdvancement.automatic?(candidate['group_advancement'])
          raise Publication::Invalid, :invalid_knockout_configuration unless count == 2
          plan = GroupTiebreak.build(snapshot: GroupTiebreak.snapshot(summary: summary, candidate: candidate, record: record), attempt: 1)
          raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != plan['seeds']
        else
        unless summary['complete'] && %w[awaiting_seeding ready_knockout].include?(summary['group_state'])
          raise Publication::Invalid, :group_stage_incomplete
        end
      if summary['group_state'] == 'ready_knockout'
        raise Publication::Invalid, :invalid_knockout_configuration unless count == 2
        automatic = summary.fetch('cross_seeding').fetch('seeds')
        raise Publication::Invalid, :invalid_qualification_seeding if seeds && seeds != automatic
        seeds = automatic
      end
      plan = KnockoutRound.from_qualification(qualified: summary['qualified'], seeds: seeds, players_per_match: count)
        end
      end
      unless plan.key?('replay') || plan.key?('qualification') || plan.key?('series')
        setting = plan['seeds'].size == count ? 'final_rematch' : 'knockout_rematch'
        target=candidate[setting.sub('rematch','wins_to')]
        plan = target ? KnockoutWinSeries.build(base:plan,history:[],target:target,attempt:1) : candidate[setting] == true ? plan.merge('rematch'=>true) : plan
      end
      evidence = record['evidence']
      parent = {'intent_id' => intent, 'expected_source' => record['expected_source'],
        'plan_digest' => evidence['plan_digest'], 'plan_id' => evidence['plan']['id'],
        'plan_revision' => evidence['plan']['revision'], 'seal' => evidence['seal']}
      body = {'version' => 1, 'parent' => parent, 'receipts' => receipts.sort_by { |r| [r['match_id'], r['leg']] },
        'plan' => plan, 'dispatch_allowed' => false}
      frozen_copy(body.merge('digest' => digest(body)))
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(frozen_copy(value)))
    end

    def shape!(shown)
      CoordinationRequest.fields!(shown, %w[version parent receipts plan dispatch_allowed digest])
      CoordinationRequest.fields!(shown['parent'], %w[intent_id expected_source plan_digest plan_id plan_revision seal])
      fields = %w[generation round seeds players_per_match byes matches dispatch_allowed]
      fields += ['replay'] if shown['plan'].key?('replay')
      fields += ['rematch'] if shown['plan'].key?('rematch')
      fields += ['qualification'] if shown['plan'].key?('qualification')
      fields += ['series'] if shown['plan'].key?('series')
      CoordinationRequest.fields!(shown['plan'], fields)
      raise Publication::Invalid, :phase_changed unless shown['version'].eql?(1) && shown['dispatch_allowed'].equal?(false)
    end

    def frozen_copy(value)
      Data.freeze_tree(Data.copy(value, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16))
    end
  end
end
