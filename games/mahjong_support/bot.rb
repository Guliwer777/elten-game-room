# frozen_string_literal: true
require_relative 'hand'
require_relative 'mcr_shapes'

module GameRoomMahjong
  module Bot
    module_function

    # The strategy receives only its own hand and public visible tile counts.
    # There is deliberately no opponent-hand or future-wall parameter.
    def discard_kind(concealed:, melds: [], public_counts: {}, choices: nil, variant: 'riichi')
      Hand.counts_for(concealed, melds)
      unless %w[riichi hong_kong mcr].include?(variant) && concealed.length == 14 - 3 * melds.length && public_counts.is_a?(Hash)
        raise ArgumentError, 'Invalid mahjong bot observation'
      end
      own = concealed.tally
      public_counts.each do |kind, count|
        Tiles.validate_kind(kind, bonuses: false)
        raise ArgumentError, 'Invalid public mahjong count' unless count.is_a?(Integer) && count.between?(0, 4)
      end
      known_public = public_counts.dup
      melds.flat_map { |group| Hand.tiles_for(group) }.tally.each do |kind, count|
        known_public[kind] = [known_public.fetch(kind, 0), count].max
      end
      known_public.each do |kind, count|
        Tiles.validate_kind(kind, bonuses: false)
        unless count.is_a?(Integer) && count.between?(0, 4) && count + own.fetch(kind, 0) <= 4
          raise ArgumentError, 'Visible mahjong counts exceed the tile inventory'
        end
      end
      choices ||= concealed.uniq
      unless choices.is_a?(Array) && !choices.empty? && choices.all? { |kind| kind.is_a?(Integer) && concealed.include?(kind) }
        raise ArgumentError, 'Bot discard choices must be legal owned tiles'
      end
      memo = {}
      choices.uniq.min_by do |kind|
        rest = concealed.dup
        rest.delete_at(rest.index(kind))
        distance = shanten(rest, melds: melds, variant: variant, memo: memo)
        # Keep useful links without counting unseen opponents' tiles as known.
        counts = rest.tally
        potential = counts.sum do |tile, count|
          available = 4 - known_public.fetch(tile, 0) - own.fetch(tile, 0)
          links = count >= 2 ? available * 2 : available
          if tile < 27
            [-2, -1, 1, 2].each do |offset|
              neighbor = tile + offset
              next unless neighbor.between?(0, 26) && neighbor / 9 == tile / 9
              links += (4 - known_public.fetch(neighbor, 0) - own.fetch(neighbor, 0)) if counts.key?(neighbor)
            end
          end
          links
        end
        [distance, -potential, own.fetch(kind), kind]
      end
    end

    def shanten(concealed, melds: [], variant: 'riichi', memo: {})
      counts = Hand.counts_for(concealed, melds)
      raise ArgumentError, 'Unknown mahjong bot variant' unless %w[riichi hong_kong mcr].include?(variant)
      return -1 unless (variant == 'mcr' ? MCRShapes.forms(concealed, melds: melds) : Hand.forms(concealed, melds: melds, split_quads: variant == 'hong_kong')).empty?
      result = distance(counts, melds.length, 0, 0, memo)
      if melds.empty?
        pairs = counts.count { |count| count >= 2 }
        pairs = counts.sum { |count| count / 2 } unless variant == 'riichi'
        pair_distance = 6 - pairs + (variant == 'riichi' ? [0, 7 - counts.count(&:positive?)].max : 0)
        result = [result, pair_distance].min
        orphan_unique = Tiles::ORPHANS.count { |kind| counts[kind].positive? }
        orphan_pair = Tiles::ORPHANS.any? { |kind| counts[kind] >= 2 } ? 1 : 0
        result = [result, 13 - orphan_unique - orphan_pair].min
        if variant == 'mcr'
          MCRShapes::KNITTED.each do |knitted|
            unique = (knitted + (27..33).to_a).count { |kind| counts[kind].positive? }
            result = [result, 13 - [unique, 14].min].min
          end
        end
      end
      result
    end

    def distance(counts, complete, partial, pair, memo)
      key = [counts.pack('C*'), complete, partial, pair]
      return memo[key] if memo.key?(key)
      first = counts.index(&:positive?)
      return 8 - 2 * complete - [partial, 4 - complete].min - pair if first.nil?
      best = 8
      # Leaving one isolated tile unused is essential: a greedy meld-only
      # decomposition gets ambiguous hands and pair waits wrong.
      counts[first] -= 1
      best = [best, distance(counts, complete, partial, pair, memo)].min
      counts[first] += 1
      if complete < 4 && counts[first] >= 3
        counts[first] -= 3
        best = [best, distance(counts, complete + 1, partial, pair, memo)].min
        counts[first] += 3
      end
      if complete < 4 && first < 27 && first % 9 <= 6 && counts[first + 1].positive? && counts[first + 2].positive?
        3.times { |offset| counts[first + offset] -= 1 }
        best = [best, distance(counts, complete + 1, partial, pair, memo)].min
        3.times { |offset| counts[first + offset] += 1 }
      end
      if counts[first] >= 2
        counts[first] -= 2
        best = [best, distance(counts, complete, partial, 1, memo)].min if pair.zero?
        best = [best, distance(counts, complete, partial + 1, pair, memo)].min if partial < 4
        counts[first] += 2
      end
      if first < 27 && partial < 4
        [1, 2].each do |offset|
          other = first + offset
          next unless other < 27 && first / 9 == other / 9 && counts[other].positive?
          counts[first] -= 1
          counts[other] -= 1
          best = [best, distance(counts, complete, partial + 1, pair, memo)].min
          counts[first] += 1
          counts[other] += 1
        end
      end
      memo[key] = best
    end
    private_class_method :distance
  end
end
