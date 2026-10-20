# frozen_string_literal: true
require_relative 'mcr_shapes'

module GameRoomMahjong
  # Candidate detection only. The MCR non-repeat/non-separation/account-once
  # rules still have to select compatible candidates before accepting a win.
  # A list from this module must never be summed as the final fan score.
  module MCRPatterns
    Candidate = Struct.new(:id, :points, :sets, :scope, keyword_init: true)
    POINTS = (Array.new(7, 88) + Array.new(6, 64) + Array.new(2, 48) +
      Array.new(3, 32) + Array.new(9, 24) + Array.new(6, 16) +
      Array.new(5, 12) + Array.new(10, 8) + Array.new(6, 6) +
      Array.new(4, 4) + Array.new(10, 2) + Array.new(13, 1)).freeze
    module_function

    def candidates(concealed:, winning_tile:, form:, melds: [], self_draw: false,
        seat_wind: 27, round_wind: 27, flowers: 0, flags: {}, placement: nil, wait: nil)
      Tiles.validate_kind(winning_tile, bonuses: false)
      unless concealed.is_a?(Array) && concealed.include?(winning_tile) &&
          [seat_wind, round_wind].all? { |kind| kind.is_a?(Integer) && kind.between?(27, 30) } &&
          flowers.is_a?(Integer) && flowers.between?(0, 8) && [true, false].include?(self_draw) &&
          flags.is_a?(Hash) && (flags.keys - %i[last_draw last_discard replacement robbing_kong last_kind]).empty? &&
          flags.values.all? { |value| value == true || value == false } &&
          form.is_a?(Hand::Form) && melds.is_a?(Array) && melds.all? { |meld| meld.is_a?(Array) && meld.length == 3 && [true, false].include?(meld[2]) && (meld[2] || meld[0] == :kong) }
        raise ArgumentError, 'Invalid MCR pattern context'
      end
      if flags[:last_draw] && !self_draw || flags[:last_discard] && self_draw ||
          flags[:replacement] && !self_draw || flags[:robbing_kong] && self_draw
        raise ArgumentError, 'Inconsistent MCR winning context'
      end
      raw_melds = melds.map { |meld| meld.first(2) }
      valid = MCRShapes.forms(concealed, melds: raw_melds).any? do |candidate|
        candidate.type == form.type && candidate.pair == form.pair && candidate.groups == form.groups
      end
      raise ArgumentError, 'The supplied MCR decomposition is not a winning hand' unless valid
      locations = MCRShapes.winning_locations(form, winning_tile, melds.length, concealed: concealed)
      if placement.nil? && wait.nil?
        placement, wait = locations.first
      end
      raise ArgumentError, 'Invalid MCR winning-tile placement' unless locations.include?([placement, wait])
      result = []
      add = lambda do |id, sets = nil, points = nil, scope = nil|
        result << Candidate.new(id: id, points: points || POINTS.fetch(id - 1), sets: sets&.dup&.freeze,
          scope: scope&.dup&.freeze).freeze
      end
      groups = form.groups
      all = concealed + raw_melds.flat_map { |group| Hand.tiles_for(group) }
      counts = all.tally
      before = concealed.dup
      before.delete_at(before.index(winning_tile))
      suits = all.select { |kind| kind < 27 }.map { |kind| kind / 9 }.uniq
      honors = all.any? { |kind| kind >= 27 }
      closed = melds.none? { |meld| meld[2] }
      standard = form.type == :standard
      chow_indices = groups.each_index.select { |index| groups[index][0] == :chow }
      pung_indices = groups.each_index.select { |index| groups[index][0] != :chow }
      wind_indices = pung_indices.select { |index| groups[index][1].between?(27, 30) }
      dragon_indices = pung_indices.select { |index| groups[index][1] >= 31 }
      kong_indices = pung_indices.select { |index| groups[index][0] == :kong }
      concealed_indices = pung_indices.reject { |index| melds[index]&.[](2) || !self_draw && index == placement }
      concealed_kongs = kong_indices.reject { |index| melds[index]&.[](2) }
      open_kongs = kong_indices - concealed_kongs
      context = {
        form: form, melds: melds, before: before, suits: suits,
        honors: honors, all: all, counts: counts, kong_indices: kong_indices,
        wind_indices: wind_indices, dragon_indices: dragon_indices, concealed_indices: concealed_indices, chow_indices: chow_indices,
        pung_indices: pung_indices, groups: groups, concealed: concealed, closed: closed,
        self_draw: self_draw, concealed_kongs: concealed_kongs, open_kongs: open_kongs, flags: flags,
        round_wind: round_wind, seat_wind: seat_wind, raw_melds: raw_melds, winning_tile: winning_tile,
        wait: wait, flowers: flowers, standard: standard
      }
      higher_patterns(context, add)
      basic_patterns(context, add)
      group_patterns(groups, chow_indices, pung_indices, add)
      result.freeze
    end

    def higher_patterns(context, add)
      standard = context.fetch(:standard)
      form, melds, before, suits, honors, all, counts, kong_indices, wind_indices, dragon_indices, concealed_indices, chow_indices, pung_indices, groups, concealed = context.values_at(
        :form, :melds, :before, :suits, :honors, :all, :counts, :kong_indices, :wind_indices, :dragon_indices, :concealed_indices, :chow_indices, :pung_indices, :groups, :concealed)
      add.call(1, nil, nil, wind_indices) if wind_indices.length == 4
      add.call(2, nil, nil, dragon_indices) if dragon_indices.length == 3
      add.call(3) if all.all? { |kind| [19, 20, 21, 23, 25, 32].include?(kind) }
      if melds.empty? && suits.length == 1 && !honors
        base = suits.first * 9
        original = before.tally
        add.call(4) if (0...9).all? { |rank| original.fetch(base + rank, 0) == ([0, 8].include?(rank) ? 3 : 1) }
      end
      add.call(5) if kong_indices.length == 4
      if form.type == :seven_pairs && suits.length == 1 && !honors
        kinds = counts.keys.sort
        add.call(6) if kinds.length == 7 && counts.values.all? { |count| count == 2 } && kinds == (kinds.first...(kinds.first + 7)).to_a
      end
      add.call(7) if form.type == :thirteen_orphans
      add.call(8) if all.all? { |kind| kind < 27 && [0, 8].include?(kind % 9) }
      add.call(9, nil, nil, wind_indices) if wind_indices.length == 3 && form.pair&.between?(27, 30)
      add.call(10, nil, nil, dragon_indices) if dragon_indices.length == 2 && form.pair&.between?(31, 33)
      add.call(11) if suits.empty?
      add.call(12) if concealed_indices.length == 4
      if standard && chow_indices.length == 4 && suits.length == 1 && !honors
        ranks = chow_indices.map { |index| groups[index][1] % 9 }.sort
        add.call(13) if ranks == [0, 0, 6, 6] && form.pair % 9 == 4
      end
      add.call(17) if kong_indices.length == 3
      add.call(18) if all.all? { |kind| Tiles.terminal_or_honor?(kind) }
      add.call(19) if form.type == :seven_pairs
      add.call(20) if form.type == :greater_knitted
      add.call(21) if standard && pung_indices.length == 4 && all.all? { |kind| kind < 27 && (kind % 9).odd? }
      add.call(22) if suits.length == 1 && !honors
      add.call(25) if all.all? { |kind| kind < 27 && kind % 9 >= 6 }
      add.call(26) if all.all? { |kind| kind < 27 && (kind % 9).between?(3, 5) }
      add.call(27) if all.all? { |kind| kind < 27 && kind % 9 <= 2 }
      if standard && chow_indices.length == 4 && form.pair < 27 && form.pair % 9 == 4
        chows = chow_indices.map { |index| groups[index][1] }
        other_suits = [0, 1, 2] - [form.pair / 9]
        expected = other_suits.flat_map { |suit| [suit * 9, suit * 9 + 6] }.sort
        add.call(29) if chows.sort == expected
      end
      if standard && form.pair < 27 && form.pair % 9 == 4 && groups.all? { |group| Hand.tiles_for(group).any? { |kind| kind < 27 && kind % 9 == 4 } }
        add.call(31)
      end
      add.call(33) if concealed_indices.length == 3
      add.call(34) if form.type == :lesser_knitted
      if form.type == :knitted_straight || form.type == :lesser_knitted && MCRShapes::KNITTED.any? { |knitted| (knitted - concealed).empty? }
        add.call(35)
      end
      add.call(36) if all.all? { |kind| kind < 27 && kind % 9 >= 5 }
      add.call(37) if all.all? { |kind| kind < 27 && kind % 9 <= 3 }
    end

    def basic_patterns(context, add)
      standard = context.fetch(:standard)
      form, melds, before, suits, honors, all, counts, kong_indices, wind_indices, dragon_indices, concealed_indices, chow_indices, pung_indices, groups, closed, self_draw, concealed_kongs, open_kongs, flags, round_wind, seat_wind, raw_melds, winning_tile, wait, flowers = context.values_at(
        :form, :melds, :before, :suits, :honors, :all, :counts, :kong_indices, :wind_indices, :dragon_indices, :concealed_indices, :chow_indices, :pung_indices, :groups, :closed, :self_draw, :concealed_kongs, :open_kongs, :flags, :round_wind, :seat_wind, :raw_melds, :winning_tile, :wait, :flowers)
      add.call(38, nil, nil, wind_indices) if wind_indices.length >= 3
      reversible = [9, 10, 11, 12, 13, 16, 17, 19, 21, 22, 23, 25, 26, 31]
      add.call(40) if all.all? { |kind| reversible.include?(kind) }
      add.call(44) if flags[:last_draw]
      add.call(45) if flags[:last_discard]
      add.call(46) if flags[:replacement]
      add.call(47) if flags[:robbing_kong]
      add.call(48) if concealed_kongs.length == 2
      add.call(49) if standard && pung_indices.length == 4
      add.call(50) if suits.length == 1 && honors
      add.call(52) if suits.length == 3 && all.any? { |kind| kind.between?(27, 30) } && all.any? { |kind| kind >= 31 }
      add.call(53) if melds.length == 4 && !closed && melds.all? { |meld| meld[2] } && !self_draw
      add.call(54, nil, nil, dragon_indices) if dragon_indices.length >= 2
      add.call(55) if standard && Tiles.terminal_or_honor?(form.pair) && groups.all? { |group| Hand.tiles_for(group).any? { |kind| Tiles.terminal_or_honor?(kind) } }
      add.call(56) if closed && self_draw
      add.call(57) if open_kongs.length == 2
      add.call(57, nil, 6) if kong_indices.length == 2 && concealed_kongs.length == 1
      add.call(58) if flags[:last_kind]
      dragon_indices.each { |index| add.call(59, [index]) }
      pung_indices.each do |index|
        kind = groups[index][1]
        add.call(60, [index]) if kind == round_wind
        add.call(61, [index]) if kind == seat_wind
        if kind < 27 && Tiles.terminal_or_honor?(kind) || kind.between?(27, 30) && ![seat_wind, round_wind].include?(kind)
          add.call(73, [index])
        end
      end
      add.call(62) if closed && !self_draw
      all_chows = standard && chow_indices.length == 4 ||
        form.type == :knitted_straight && groups.length == 1 && groups.first[0] == :chow
      add.call(63) if all_chows && !honors
      counts.each { |kind, count| add.call(64, nil) if count == 4 && kong_indices.none? { |index| groups[index][1] == kind } }
      add.call(66) if concealed_indices.length == 2
      concealed_kongs.each { |index| add.call(67, [index]) }
      add.call(68) if all.none? { |kind| Tiles.terminal_or_honor?(kind) }
      open_kongs.each { |index| add.call(74, [index]) }
      add.call(75) if suits.length == 2
      add.call(76) unless honors
      if (standard || form.type == :knitted_straight) && MCRShapes.waits(before, melds: raw_melds) == [winning_tile]
        add.call(77) if wait == :edge
        add.call(78) if wait == :closed
        add.call(79) if wait == :pair
      end
      add.call(80) if self_draw
      add.call(81, nil, flowers) if flowers.positive?
    end

    def group_patterns(groups, chows, pungs, add)
      chows.combination(4) do |indices|
        kinds = indices.map { |index| groups[index][1] }.sort
        add.call(14, indices) if kinds.uniq.length == 1
        add.call(16, indices) if shifted?(kinds, [1, 2])
      end
      pungs.combination(4) do |indices|
        kinds = indices.map { |index| groups[index][1] }.sort
        add.call(15, indices) if shifted?(kinds, [1])
      end
      chows.combination(3) do |indices|
        kinds = indices.map { |index| groups[index][1] }.sort
        suits = kinds.map { |kind| kind / 9 }.uniq
        ranks = kinds.map { |kind| kind % 9 }.sort
        add.call(23, indices) if kinds.uniq.length == 1
        add.call(28, indices) if suits.length == 1 && ranks == [0, 3, 6]
        add.call(30, indices) if shifted?(kinds, [1, 2])
        add.call(39, indices) if suits.length == 3 && ranks == [0, 3, 6]
        add.call(41, indices) if suits.length == 3 && ranks.uniq.length == 1
        add.call(51, indices) if suits.length == 3 && ranks.each_cons(2).all? { |first, second| second == first + 1 }
      end
      pungs.combination(3) do |indices|
        kinds = indices.map { |index| groups[index][1] }.sort
        next if kinds.any? { |kind| kind >= 27 }
        suits = kinds.map { |kind| kind / 9 }.uniq
        ranks = kinds.map { |kind| kind % 9 }.sort
        add.call(24, indices) if shifted?(kinds, [1])
        add.call(32, indices) if suits.length == 3 && ranks.uniq.length == 1
        add.call(42, indices) if suits.length == 3 && ranks.each_cons(2).all? { |first, second| second == first + 1 }
      end
      chows.combination(2) do |indices|
        first, second = indices.map { |index| groups[index][1] }.sort
        add.call(69, indices) if first == second
        add.call(70, indices) if first % 9 == second % 9 && first / 9 != second / 9
        add.call(71, indices) if first / 9 == second / 9 && second - first == 3
        add.call(72, indices) if first / 9 == second / 9 && first % 9 == 0 && second % 9 == 6
      end
      pungs.combination(2) do |indices|
        first, second = indices.map { |index| groups[index][1] }
        add.call(65, indices) if first < 27 && second < 27 && first % 9 == second % 9 && first / 9 != second / 9
      end
    end

    def shifted?(kinds, steps)
      kinds.all? { |kind| kind < 27 && kind / 9 == kinds.first / 9 } &&
        steps.any? { |step| kinds.each_cons(2).all? { |first, second| second - first == step } }
    end
    private_class_method :higher_patterns, :basic_patterns, :group_patterns, :shifted?
  end
end
