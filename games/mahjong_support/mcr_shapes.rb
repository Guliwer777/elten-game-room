# frozen_string_literal: true
require_relative 'hand'

module GameRoomMahjong
  module MCRShapes
    KNITTED = [0, 1, 2].permutation.map do |offsets|
      offsets.each_with_index.flat_map do |offset, suit|
        [offset, offset + 3, offset + 6].map { |rank| suit * 9 + rank }
      end.freeze
    end.freeze
    module_function

    def forms(concealed, melds: [])
      Hand.counts_for(concealed, melds)
      return [] unless concealed.length == 14 - melds.length * 3
      ordinary = Hand.forms(concealed, melds: melds, split_quads: true)
      return ordinary if melds.length > 1
      result = ordinary.dup
      counts = concealed.tally
      KNITTED.each do |knitted|
        if melds.empty? && concealed.uniq.length == 14 && (concealed - knitted - (27..33).to_a).empty?
          honors = concealed.count { |kind| kind >= 27 }
          if honors.between?(5, 7)
            result << Hand::Form.new(type: honors == 7 ? :greater_knitted : :lesser_knitted, groups: [].freeze).freeze
          end
        end
        next unless knitted.all? { |kind| counts.fetch(kind, 0).positive? }
        remainder = concealed.dup
        knitted.each { |kind| remainder.delete_at(remainder.index(kind)) }
        remainder.tally.each do |pair, count|
          next if count < 2
          sets = remainder.dup
          2.times { sets.delete_at(sets.index(pair)) }
          group = if sets.empty? && melds.length == 1
            []
          elsif melds.empty? && sets.length == 3
            sorted = sets.sort
            if sorted.uniq.length == 1
              [[:pung, sorted.first]]
            elsif sorted.first < 27 && sorted.first % 9 <= 6 && sorted == [sorted.first, sorted.first + 1, sorted.first + 2]
              [[:chow, sorted.first]]
            end
          end
          next if group.nil?
          result << Hand::Form.new(type: :knitted_straight, pair: pair,
            groups: (melds + group).map { |set| set.dup.freeze }.freeze).freeze
        end
      end
      result.uniq { |form| [form.type, form.pair, form.groups] }.freeze
    end

    def waits(concealed, melds: [])
      Hand.counts_for(concealed, melds)
      return [] unless concealed.length == 13 - 3 * melds.length
      owned = (concealed + melds.flat_map { |group| Hand.tiles_for(group) }).tally
      (0...34).select { |kind| owned.fetch(kind, 0) < 4 && !forms(concealed + [kind], melds: melds).empty? }
    end

    def winning_locations(form, tile, exposed_count, concealed:)
      return Hand.winning_locations(form, tile, exposed_count) unless form.type == :knitted_straight
      ordinary = Hand::Form.new(type: :standard, pair: form.pair, groups: form.groups)
      locations = Hand.winning_locations(ordinary, tile, exposed_count)
      knitted = concealed.dup
      2.times { knitted.delete_at(knitted.index(form.pair)) }
      form.groups.drop(exposed_count).each do |group|
        Hand.tiles_for(group).each { |kind| knitted.delete_at(knitted.index(kind)) }
      end
      locations << [nil, :special] if knitted.include?(tile)
      locations
    end
  end
end
