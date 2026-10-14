require_relative 'publication'

module GameRoomTournaments
  module GroupAdvancement
    AUTOMATIC = 'automatic_cross_groups_v1'.freeze
    COMPACT = 'automatic_compact_groups_v2'.freeze
    def self.automatic?(policy)
      [AUTOMATIC, COMPACT].include?(policy)
    end
    def self.target(total, policy: AUTOMATIC)
      policy == COMPACT && total == 9 ? 4 : (1 << (total.bit_length - 1))
    end
    module_function

    def power_of_two?(number)
      number.is_a?(Integer) && number >= 2 && (number & (number - 1)).zero?
    end

    def group_count(total, policy: AUTOMATIC)
      unless total.is_a?(Integer) && total.between?(4, 256)
        raise Publication::Invalid, :invalid_group_configuration
      end
      policy == COMPACT ? [2, (total + 3) / 4].max : (total > 16 ? 4 : 2)
    end

    # User policy: two groups through 16 units, four thereafter; advance the
    # largest power of two not exceeding the roster, equally from each group.
    def places(group_sizes:, policy:, explicit:)
      return group_sizes.map { explicit } if policy.nil?
      total = group_sizes.sum
      unless automatic?(policy) && group_sizes.size == group_count(total, policy: policy)
        raise Publication::Invalid, :invalid_group_configuration
      end
      target = self.target(total, policy: policy)
      if policy == COMPACT
        expected = Array.new(group_sizes.size, total / group_sizes.size)
        (total % group_sizes.size).times { |i| expected[i] += 1 }
        raise Publication::Invalid, :invalid_group_configuration unless group_sizes == expected
      end
      places = target / group_sizes.size
      unless group_sizes.all? { |size| size >= places }
        raise Publication::Invalid, :invalid_group_configuration
      end
      group_sizes.map { places }
    end
  end
end
