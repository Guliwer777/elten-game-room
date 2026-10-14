require_relative 'league_plan'
require_relative 'group_qualification'
require_relative 'group_advancement'

module GameRoomTournaments
  # Local candidate only. The caller explicitly supplies the roster order;
  # distribution neither invents seeding nor changes an accepted roster.
  class GroupPlan
    def self.build(participants:, group_count:, places_per_group:, players_per_match:, pairing:, rematch:, advancement: nil)
      if GroupAdvancement.automatic?(advancement)
        begin
          group_count = GroupAdvancement.group_count(participants.is_a?(Array) ? participants.size : nil, policy: advancement)
        rescue Publication::Invalid => error
          raise LeaguePlan::Invalid, error.code
        end
      end
      unless participants.is_a?(Array) && participants.size.between?(4, 256) &&
          group_count.is_a?(Integer) && group_count.between?(2, 128) &&
          players_per_match.is_a?(Integer) && players_per_match.between?(2, 8) &&
          participants.size / group_count >= players_per_match &&
          (GroupAdvancement.automatic?(advancement) ||
            (advancement.nil? && places_per_group.is_a?(Integer) && places_per_group.between?(1, participants.size / group_count)))
        raise LeaguePlan::Invalid, :invalid_group_configuration
      end
      # Validate across groups too: the league planner alone would not see a
      # duplicated account in two different groups. No large global fixture set.
      unless participants.all? { |name| name.is_a?(String) }
        raise LeaguePlan::Invalid, :invalid_participants
      end
      groups = Array.new(group_count) { [] }
      participants.each_with_index { |unit, index| groups[index % group_count] << unit }
      begin
        places = GroupAdvancement.places(group_sizes: groups.map(&:size), policy: advancement, explicit: places_per_group)
      rescue Publication::Invalid => error
        raise LeaguePlan::Invalid, error.code
      end
      total = 0
      plans = groups.map.with_index do |units, index|
        fixtures = LeaguePlan.build(participants: units, players_per_match: players_per_match,
          pairing: pairing, rematch: rematch)
        # Qualification uses the existing bounded standings contract (256).
        raise LeaguePlan::Invalid, :too_many_group_matches if fixtures.size > 256
        total += fixtures.size
        raise LeaguePlan::Invalid, :too_many_matches if total > 5000
        group_id = "group-#{index + 1}"
        {'id' => group_id, 'units' => units, 'places' => places[index],
          'matches' => fixtures.map { |match| {
            'id' => "#{group_id}-match-#{match['number']}", 'participants' => match['players'], 'leg' => match['leg']
          } }}
      end
      # LeaguePlan has now validated encoding and name syntax before downcase.
      unless participants.map(&:downcase).uniq.size == participants.size
        raise LeaguePlan::Invalid, :invalid_participants
      end
      Publication::Data.freeze_tree(Publication::Data.copy({
        'state' => 'local_candidate', 'dispatch_allowed' => false,
        'distribution' => 'cyclic_roster_order', 'groups' => plans,
        'match_count' => total, 'qualification_places' => places.sum
      }, max_bytes: 4_194_304, max_nodes: 131_072, max_depth: 10))
    end
  end
end
