require_relative 'publication'

module GameRoomTournaments
  # Group placings determine cross-pairs; alphabetical presentation of a tie
  # cannot become a sporting seed. This projection never authorizes a Start.
  module CrossGroupSeeding
    module_function
    def build(groups:)
      unless groups.is_a?(Array) && groups.size >= 2 && groups.size.even?
        raise Publication::Invalid, :invalid_cross_group_seeding
      end
      unresolved = []
      ordered = groups.map do |group|
        qualification = group.fetch('qualification')
        unless qualification['state'] == 'ready'
          return Publication::Data.freeze_tree({'state' => 'awaiting_qualification', 'seeds' => [], 'pairs' => [], 'unresolved' => []})
        end
        qualified = qualification['qualified']
        rows = qualification['standings'].select { |row| qualified.include?(row['unit']) }.sort_by { |row| row['place'] }
        unless rows.size == qualified.size && rows.map { |row| row['unit'] }.uniq.size == rows.size
          raise Publication::Invalid, :invalid_cross_group_seeding
        end
        rows.group_by { |row| row['place'] }.each_value do |tied|
          unresolved.concat(tied.map { |row| row['unit'] }) if tied.size > 1
        end
        rows.map { |row| row['unit'] }
      end
      if unresolved.any?
        return Publication::Data.freeze_tree(Publication::Data.copy({'state' => 'tie_requires_resolution',
          'seeds' => [], 'pairs' => [], 'unresolved' => unresolved}))
      end
      pairs = ordered.each_slice(2).flat_map do |left, right|
        unless !left.empty? && left.size == right.size
          raise Publication::Invalid, :invalid_cross_group_seeding
        end
        left.zip(right.reverse)
      end
      unless pairs.flatten.uniq.size == pairs.flatten.size
        raise Publication::Invalid, :invalid_cross_group_seeding
      end
      Publication::Data.freeze_tree(Publication::Data.copy({'state' => 'ready', 'pairs' => pairs,
        'seeds' => pairs.flatten, 'unresolved' => []}, max_bytes: 262_144, max_nodes: 16_384, max_depth: 8))
    end
  end
end
