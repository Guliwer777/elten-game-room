require_relative 'group_advancement'
require_relative 'cross_group_seeding'
require_relative 'standings'

module GameRoomTournaments
  # Cross-group comparisons exclude games against the last unit of a larger
  # group. Original group tables and accepted results remain unchanged.
  module CompactGroupSeeding
    module_function
    def build(groups:, results_by_group:, wildcard_order: {})
      total = groups.sum { |group| group['units'].size }
      target = GroupAdvancement.target(total, policy: GroupAdvancement::COMPACT)
      base = target / groups.size
      extra = target % groups.size
      selected = groups.flat_map { |group| group['qualification']['qualified'] }
      candidates = []
      unresolved = []
      eligible_sizes = groups.select { |group| group['units'].size > base }.map { |group| group['units'].size }
      minimum = eligible_sizes.min
      groups.each_with_index do |group, index|
        q = group.fetch('qualification')
        return result('awaiting_qualification') unless q['state'] == 'ready'
        table = q.fetch('standings')
        # Group ties cannot become an arbitrary sporting seed.
        table.select { |row| selected.include?(row['unit']) }.group_by { |row| row['place'] }.each_value do |tie|
          unresolved.concat(tie.map { |row| row['unit'] }) if tie.size > 1
        end
        next if extra.zero? || group['units'].size <= base
        at_boundary = table.select { |row| row['place'] == base + 1 }
        if at_boundary.size != 1
          unresolved.concat(at_boundary.map { |row| row['unit'] })
          next
        end
        own = results_by_group.fetch(index)
        units = group['units']
        excluded = nil
        if units.size > minimum
          last = table.select { |row| row['place'] == table.last['place'] }
          if last.size != 1
            unresolved.concat(last.map { |row| row['unit'] })
            next
          end
          excluded = last.first['unit']
          units = units - [excluded]
          own = own.reject { |match| match['participants'].include?(excluded) }
        end
        rows = Standings.calculate(units: units, results: own, points: Standings::MATCH_POINTS)
        row = rows.find { |item| item['unit'] == at_boundary.first['unit'] }
        raise Publication::Invalid, :invalid_cross_group_seeding unless row
        candidates << row.merge('group' => group['id'], 'excluded' => excluded)
      end
      return result('tie_requires_resolution', unresolved: unresolved.uniq) unless unresolved.empty?
      if extra.positive?
        raise Publication::Invalid, :invalid_cross_group_seeding unless candidates.map { |row| row['played'] }.uniq.size == 1
        # Missing small points do not become zero and cannot decide a tie.
        numeric = candidates.all? { |row| row['scored_matches'] == row['played'] && row['played'].positive? }
        keys = candidates.to_h do |row|
          sign = row['score_order'] == 'lower' ? -1 : 1
          [row['unit'], [row['points'], numeric ? sign * (row['score_for'] - row['score_against']) : 0,
            numeric ? sign * row['score_for'] : 0]]
        end
        tiers = candidates.group_by { |row| keys.fetch(row['unit']) }.sort_by(&:first).reverse
        tiers = tiers.flat_map do |key, tied|
          if tied.size > 1 && tied.all? { |row| wildcard_order.key?(row['unit']) }
            tied.group_by { |row| wildcard_order.fetch(row['unit']) }.sort_by(&:first).map { |_, rows| [key, rows] }
          else
            [[key, tied]]
          end
        end
        tiers.each do |_, tied|
          break if extra.zero?
          return result('tie_requires_resolution', unresolved: tied.map { |row| row['unit'] }, comparison: candidates) if tied.size > extra
          selected.concat(tied.map { |row| row['unit'] })
          extra -= tied.size
        end
      end
      raise Publication::Invalid, :invalid_cross_group_seeding unless selected.size == target && selected.uniq.size == target
      if groups.size.even? && (target % groups.size).zero?
        return CrossGroupSeeding.build(groups: groups)
      end
      result('ready', pairs: pair_selected(groups, selected), comparison: candidates)
    end

    def pair_selected(groups, selected)
      # Pair a higher group placing with a lower placing, preferring opponents
      # from another group. Equal cross-group placings have no sporting order.
      entries = groups.flat_map do |group|
        group['qualification']['standings'].select { |row| selected.include?(row['unit']) }
          .map { |row| row.merge('group' => group['id']) }
      end.sort_by { |row| [row['place'], row['group']] }
      pairs = []
      until entries.empty?
        first = entries.shift
        index = (entries.size - 1).downto(0).find { |i| entries[i]['group'] != first['group'] } || entries.size - 1
        pairs << [first['unit'], entries.delete_at(index)['unit']]
      end
      pairs
    end

    def result(state, pairs: [], unresolved: [], comparison: [])
      Publication::Data.freeze_tree(Publication::Data.copy({'state' => state, 'pairs' => pairs,
        'seeds' => pairs.flatten, 'unresolved' => unresolved, 'comparison' => comparison},
        max_bytes: 524_288, max_nodes: 32_768, max_depth: 10))
    end
  end
end
