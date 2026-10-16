require_relative 'group_plan'

module GameRoomTournaments
  # Common bridge from group units to the existing accepted match contracts.
  module GroupSchedule
    module_function
    def build(roster:, settings:, players_per_match:)
      plan = GroupPlan.build(participants: roster, group_count: settings['group_count'],
        places_per_group: settings['places_per_group'], players_per_match: players_per_match,
        pairing: settings['pairing'], rematch: settings['rematch'], advancement: settings['group_advancement'])
      raise Publication::Invalid, :plan_too_large if plan['match_count'] > 256
      matches = []
      groups = plan['groups'].map do |group|
        numbers = group['matches'].map do |match|
          number = matches.size + 1
          matches << {'number' => number, 'players' => match['participants'], 'leg' => match['leg']}
          number
        end
        group.slice('id', 'units', 'places').merge('match_numbers' => numbers)
      end
      [matches, groups]
    rescue LeaguePlan::Invalid => error
      code = if [:too_many_matches, :too_many_group_matches].include?(error.code)
        :plan_too_large
      elsif error.code == :qualification_policy_unresolved
        error.code
      else
        :invalid_group_configuration
      end
      raise Publication::Invalid.new(code), cause: error
    end
    def metadata(groups, matches, unit_mapping: nil)
      groups.map do |group|
        {'id' => group['id'], 'units' => group['units'].map { |id| unit_mapping ? unit_mapping.fetch(id) : id },
          'places' => group['places'],
          'matches' => group['match_numbers'].map { |number| matches.fetch(number - 1)['match_id'] }}
      end
    end

    def validate!(candidate, units:, unit_key:, players_per_match:)
      unless candidate.is_a?(Hash) && units.is_a?(Array) && units.size.between?(2, 256) &&
          units.uniq == units && units.all? { |unit| unit.is_a?(String) } &&
          players_per_match.is_a?(Integer) && players_per_match.between?(2, 8)
        raise Publication::Invalid, :invalid_group_configuration
      end
      groups = candidate['groups']
      matches = candidate['matches']
      unless groups.is_a?(Array) && groups.size.between?(2, 128) &&
          matches.is_a?(Array) && matches.size.between?(1, 256) &&
          matches.all? { |match| match.is_a?(Hash) && match['match_id'].is_a?(String) } &&
          matches.map { |match| match['match_id'] }.uniq.size == matches.size
        raise Publication::Invalid, :invalid_group_configuration
      end
      all_units, all_matches = [], []
      groups.each_with_index do |group, index|
        unless group.is_a?(Hash) && group.keys.sort == %w[id matches places units] &&
            group['id'] == "group-#{index + 1}" && group['units'].is_a?(Array) &&
            group['units'].size.between?(players_per_match, 256) && group['units'].uniq == group['units'] &&
            group['units'].all? { |unit| unit.is_a?(String) } &&
            group['places'].is_a?(Integer) && group['places'].between?(1, group['units'].size) &&
            group['matches'].is_a?(Array) && group['matches'].size.between?(1, 256) &&
            group['matches'].all? { |id| id.is_a?(String) }
          raise Publication::Invalid, :invalid_group_configuration
        end
        own = group['matches'].map { |id| matches.find { |match| match['match_id'] == id } }
        unless own.all? { |match| match && match[unit_key].is_a?(Array) &&
            match[unit_key].size == players_per_match && match[unit_key].uniq == match[unit_key] &&
            (match[unit_key] - group['units']).empty? } &&
            (group['units'] - own.flat_map { |match| match[unit_key] }).empty?
          raise Publication::Invalid, :invalid_group_configuration
        end
        all_units.concat(group['units'])
        all_matches.concat(group['matches'])
      end
      unless all_units.uniq.size == all_units.size && all_units.sort == units.sort &&
          all_matches.uniq.size == all_matches.size && all_matches.sort == matches.map { |match| match['match_id'] }.sort
        raise Publication::Invalid, :invalid_group_configuration
      end
      if candidate.key?('group_advancement')
        expected = GroupAdvancement.places(group_sizes: groups.map { |group| group['units'].size },
          policy: candidate['group_advancement'], explicit: nil)
        unless GroupAdvancement.automatic?(candidate['group_advancement']) && groups.map { |group| group['places'] } == expected
          raise Publication::Invalid, :invalid_group_configuration
        end
      end
      true
    end
  end
end
