require_relative 'group_plan'
require_relative 'knockout_round'
require_relative 'cross_group_seeding'
require_relative 'compact_group_seeding'

module GameRoomTournaments
  # Whole-stage local projection. Qualification and explicit knockout seeding
  # are separate decisions; row display order is never a sporting seed.
  class GroupStage
    def self.calculate(configuration:, results:, knockout_seeds: nil)
      plan = GroupPlan.build(**configuration)
      unless results.is_a?(Array) && results.size <= 5000
        raise Publication::Invalid, :invalid_group_results
      end
      owners = plan['groups'].each_with_index.each_with_object({}) do |(group, index), map|
        group['matches'].each { |match| map[match['id']] = index }
      end
      grouped_results = Array.new(plan['groups'].size) { [] }
      results.each do |result|
        unless result.is_a?(Hash) && owners.key?(result['id'])
          raise Publication::Invalid, :result_outside_group_plan
        end
        grouped_results[owners.fetch(result['id'])] << result
      end
      groups = plan['groups'].map.with_index do |group, index|
        group.merge('qualification' => GroupQualification.calculate(units: group['units'],
          matches: group['matches'], results: grouped_results[index], places: group['places']))
      end
      states = groups.map { |group| group['qualification']['state'] }
      ready = states.all? { |state| state == 'ready' }
      state = if states.include?('awaiting_results')
        'awaiting_results'
      elsif states.include?('tie_requires_resolution')
        'tie_requires_resolution'
      else
        'awaiting_seeding'
      end
      qualified = groups.flat_map { |group| group['qualification']['qualified'] }
      knockout = nil
      cross = nil
      if ready && GroupAdvancement.automatic?(configuration[:advancement])
        cross = configuration[:advancement] == GroupAdvancement::COMPACT ?
          CompactGroupSeeding.build(groups: groups, results_by_group: grouped_results) : CrossGroupSeeding.build(groups: groups)
        state = cross['state'] == 'ready' ? 'ready_knockout' : 'seeding_tie_requires_resolution'
        if cross['state'] == 'ready'
          qualified = cross['seeds']
          raise Publication::Invalid, :invalid_knockout_configuration unless configuration.fetch(:players_per_match) == 2
          if knockout_seeds && knockout_seeds != cross['seeds']
            raise Publication::Invalid, :invalid_cross_group_seeding
          end
          knockout_seeds = cross['seeds']
        elsif knockout_seeds
          raise Publication::Invalid, :invalid_cross_group_seeding
        end
      end
      unless knockout_seeds.nil?
        raise Publication::Invalid, :group_stage_incomplete unless ready
        knockout = KnockoutRound.from_qualification(qualified: qualified, seeds: knockout_seeds,
          players_per_match: configuration.fetch(:players_per_match))
        state = 'knockout_candidate'
      end
      Publication::Data.freeze_tree(Publication::Data.copy({
        'state' => state, 'groups' => groups, 'qualified' => qualified,
        'knockout' => knockout, 'cross_seeding' => cross, 'dispatch_allowed' => false
      }, max_bytes: 8_388_608, max_nodes: 262_144, max_depth: 14))
    end
  end
end
