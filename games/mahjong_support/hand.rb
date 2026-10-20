# frozen_string_literal: true
require_relative 'tiles'

module GameRoomMahjong
  module Hand
    Form = Struct.new(:type, :pair, :groups, keyword_init: true)
    module_function

    # Return every decomposition, not just the first. The same tiles can score
    # differently as chows or pungs, or as seven pairs and a standard hand.
    # Meld entries are [:chow/:pung/:kong, first_kind]. Scoring also tracks
    # exposure separately; a concealed kong is not an exposed pung.
    def forms(concealed, melds: [], seven_pairs: true, split_quads: false, orphans: true)
      counts = counts_for(concealed, melds)
      return [] unless concealed.length == 14 - 3 * melds.length
      result = []
      if melds.empty?
        pairs = split_quads ? counts.sum { |count| count / 2 } == 7 && counts.all?(&:even?) : counts.count(2) == 7
        result << Form.new(type: :seven_pairs, groups: [].freeze).freeze if seven_pairs && pairs
        if orphans && Tiles::ORPHANS.all? { |kind| counts[kind].positive? } &&
            counts.each_index.all? { |kind| counts[kind].zero? || Tiles::ORPHANS.include?(kind) }
          result << Form.new(type: :thirteen_orphans, groups: [].freeze).freeze
        end
      end
      34.times do |pair|
        next if counts[pair] < 2
        counts[pair] -= 2
        groups(counts, 4 - melds.length).each do |sets|
          result << Form.new(type: :standard, pair: pair, groups: (melds + sets).map { |group| group.dup.freeze }.freeze).freeze
        end
        counts[pair] += 2
      end
      result.freeze
    end

    def waits(concealed, melds: [], **options)
      counts_for(concealed, melds)
      return [] unless concealed.length == 13 - 3 * melds.length
      exposed = melds.flat_map { |group| tiles_for(group) }
      owned = (concealed + exposed).tally
      (0...34).select do |kind|
        owned.fetch(kind, 0) < 4 && !forms(concealed + [kind], melds: melds, **options).empty?
      end
    end

    def winning_locations(form, tile, exposed_count)
      return [[nil, :special]] unless form.type == :standard
      result = []
      result << [nil, :pair] if form.pair == tile
      form.groups.each_with_index do |group, index|
        next if index < exposed_count || !tiles_for(group).include?(tile)
        type, first = group
        wait = if type != :chow then :triplet
        elsif tile == first + 1 then :closed
        elsif first % 9 == 0 && tile == first + 2 || first % 9 == 6 && tile == first then :edge
        else :two_sided
        end
        result << [index, wait]
      end
      result
    end

    # Analysis-only interpretations for WRC post-riichi kong restrictions.
    # The original ready hand is physically validated, but its hypothetical
    # winning tile can be a fifth copy. Such structures are NOT legal wins.
    def virtual_win_forms(concealed, melds: [])
      original = counts_for(concealed, melds)
      return [].freeze unless concealed.length == 13 - 3 * melds.length
      result = []
      34.times do |winning|
        counts = original.dup
        counts[winning] += 1
        if melds.empty?
          result << Form.new(type: :seven_pairs, groups: [].freeze).freeze if counts.count(2) == 7
          if Tiles::ORPHANS.all? { |kind| counts[kind].positive? } && counts.each_index.all? { |kind| counts[kind].zero? || Tiles::ORPHANS.include?(kind) }
            result << Form.new(type: :thirteen_orphans, groups: [].freeze).freeze
          end
        end
        34.times do |pair|
          next if counts[pair] < 2
          counts[pair] -= 2
          groups(counts, 4 - melds.length).each do |sets|
            result << Form.new(type: :standard, pair: pair,
              groups: (melds + sets).map { |group| group.dup.freeze }.freeze).freeze
          end
          counts[pair] += 2
        end
      end
      result.freeze
    end

    def counts_for(concealed, melds)
      raise ArgumentError, 'Invalid hand' unless concealed.is_a?(Array) && concealed.length <= 14 && melds.is_a?(Array) && melds.length <= 4
      counts = Array.new(34, 0)
      concealed.each { |kind| counts[Tiles.validate_kind(kind, bonuses: false)] += 1 }
      all = counts.dup
      melds.each { |group| tiles_for(group).each { |kind| all[kind] += 1 } }
      raise ArgumentError, 'More than four copies of a tile' if all.any? { |count| count > 4 }
      counts
    end

    def tiles_for(group)
      raise ArgumentError, 'Invalid meld' unless group.is_a?(Array) && group.length == 2
      type, kind = group
      Tiles.validate_kind(kind, bonuses: false)
      case type
      when :chow
        raise ArgumentError, 'Honors and suit boundaries cannot form a chow' unless kind < 27 && kind % 9 <= 6
        [kind, kind + 1, kind + 2]
      when :pung then [kind] * 3
      when :kong then [kind] * 4
      else raise ArgumentError, 'Unknown meld'
      end
    end

    def groups(counts, needed)
      first = counts.index { |count| count.positive? }
      return first.nil? ? [[]] : [] if needed.zero?
      return [] if first.nil? || counts.sum != needed * 3
      result = []
      if counts[first] >= 3
        counts[first] -= 3
        groups(counts, needed - 1).each { |rest| result << [[:pung, first]] + rest }
        counts[first] += 3
      end
      if first < 27 && first % 9 <= 6 && counts[first + 1].positive? && counts[first + 2].positive?
        3.times { |offset| counts[first + offset] -= 1 }
        groups(counts, needed - 1).each { |rest| result << [[:chow, first]] + rest }
        3.times { |offset| counts[first + offset] += 1 }
      end
      result
    end
    private_class_method :groups
  end
end
