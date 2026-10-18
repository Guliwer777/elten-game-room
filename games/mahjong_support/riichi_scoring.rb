# frozen_string_literal: true
require_relative 'hand'
require_relative 'payments'

module GameRoomMahjong
  module RiichiScoring
    Result = Struct.new(:han, :fu, :yakuman, :yaku, :form, :wait, keyword_init: true)
    module_function

    # Concealed includes the winning tile. Melds: [type, first_kind, open].
    # Context flags are supplied by accepted history, never by a win request.
    def score(concealed:, winning_tile:, melds: [], self_draw: false,
        seat_wind: 27, round_wind: 27, riichi: 0, dora: 0, flags: {})
      Tiles.validate_kind(winning_tile, bonuses: false)
      raise ArgumentError, 'Winning tile absent from hand' unless concealed.is_a?(Array) && concealed.include?(winning_tile)
      unless seat_wind.is_a?(Integer) && round_wind.is_a?(Integer) && [27, 28, 29, 30].include?(seat_wind) && [27, 28, 29, 30].include?(round_wind) &&
          riichi.is_a?(Integer) && [0, 1, 2].include?(riichi) && dora.is_a?(Integer) && dora.between?(0, 40) &&
          [true, false].include?(self_draw) && flags.is_a?(Hash) &&
          (flags.keys - %i[ippatsu last_draw last_discard replacement robbing_kong heavenly earthly]).empty? &&
          flags.values.all? { |value| value == true || value == false }
        raise ArgumentError, 'Invalid riichi scoring context'
      end
      unless melds.is_a?(Array) && melds.all? { |meld| meld.is_a?(Array) && meld.length == 3 && [true, false].include?(meld[2]) && (meld[2] || meld[0] == :kong) }
        raise ArgumentError, 'Invalid riichi meld exposure'
      end
      closed = melds.none? { |meld| meld[2] }
      raise ArgumentError, 'An open hand cannot declare riichi' if riichi.positive? && !closed
      raise ArgumentError, 'Ippatsu requires riichi' if flags[:ippatsu] && riichi.zero?
      if flags[:last_draw] && (!self_draw || flags[:replacement]) || flags[:last_discard] && self_draw ||
          flags[:replacement] && !self_draw || flags[:robbing_kong] && self_draw
        raise ArgumentError, 'Inconsistent riichi win context'
      end
      raw_melds = melds.map { |meld| meld.first(2) }
      forms = Hand.forms(concealed, melds: raw_melds)
      all_tiles = concealed + raw_melds.flat_map { |meld| Hand.tiles_for(meld) }
      candidates = forms.flat_map do |form|
        placements(form, winning_tile, melds.length).filter_map do |placement, wait|
          evaluate(form, placement, wait, all_tiles, melds, closed, self_draw,
            seat_wind, round_wind, riichi, dora, flags)
        end
      end
      candidates.max_by { |result| [base_points(result), result.han, result.fu] }
    end

    def placements(form, tile, exposed_count)
      Hand.winning_locations(form, tile, exposed_count)
    end

    def evaluate(form, placement, wait, all, melds, closed, self_draw, seat, round, riichi, dora, flags)
      sets = form.groups || []
      pungs = sets.each_index.select { |index| sets[index][0] != :chow }
      concealed_pungs = pungs.select do |index|
        !melds[index]&.[](2) && (self_draw || placement != index)
      end
      chows = sets.select { |type, _kind| type == :chow }.map(&:last)
      triplets = pungs.map { |index| sets[index][1] }
      kongs = sets.count { |type, _kind| type == :kong }
      suits = all.select { |kind| kind < 27 }.map { |kind| kind / 9 }.uniq
      honors = all.any? { |kind| kind >= 27 }
      all_terminals = all.all? { |kind| kind < 27 && [0, 8].include?(kind % 9) }
      yakuman = {}
      yakuman[:thirteen_orphans] = 1 if form.type == :thirteen_orphans
      yakuman[:four_concealed_pungs] = 1 if concealed_pungs.length == 4
      yakuman[:big_three_dragons] = 1 if (triplets & [31, 32, 33]).length == 3
      wind_pungs = (triplets & [27, 28, 29, 30]).length
      yakuman[:big_four_winds] = 1 if wind_pungs == 4
      yakuman[:small_four_winds] = 1 if wind_pungs == 3 && form.pair&.between?(27, 30)
      yakuman[:all_honors] = 1 if suits.empty?
      yakuman[:all_terminals] = 1 if all_terminals
      yakuman[:all_green] = 1 if all.all? { |kind| [19, 20, 21, 23, 25, 32].include?(kind) }
      yakuman[:four_kongs] = 1 if kongs == 4
      if closed && melds.empty? && suits.length == 1 && !honors
        counts = all.tally
        base = suits.first * 9
        if (0...9).all? { |offset| counts.fetch(base + offset, 0) >= ([0, 8].include?(offset) ? 3 : 1) }
          yakuman[:nine_gates] = 1
        end
      end
      yakuman[:heavenly_hand] = 1 if flags[:heavenly] && self_draw && closed && seat == 27
      yakuman[:earthly_hand] = 1 if flags[:earthly] && self_draw && closed && seat != 27
      unless yakuman.empty?
        return Result.new(han: 0, fu: 0, yakuman: yakuman.values.sum, yaku: yakuman.freeze,
          form: form, wait: wait).freeze
      end
      yaku = {}
      yaku[riichi == 2 ? :double_riichi : :riichi] = riichi if riichi.positive?
      yaku[:ippatsu] = 1 if flags[:ippatsu]
      yaku[:concealed_self_draw] = 1 if closed && self_draw
      yaku[:all_simples] = 1 if all.none? { |kind| Tiles.terminal_or_honor?(kind) }
      yaku[:last_draw] = 1 if flags[:last_draw]
      yaku[:last_discard] = 1 if flags[:last_discard]
      yaku[:replacement_draw] = 1 if flags[:replacement]
      yaku[:robbing_kong] = 1 if flags[:robbing_kong]
      if form.type == :seven_pairs
        yaku[:seven_pairs] = 2
      elsif form.type == :standard
        value_pair = form.pair >= 31 || [seat, round].include?(form.pair)
        pinfu = closed && chows.length == 4 && !value_pair && wait == :two_sided
        yaku[:pinfu] = 1 if pinfu
        double_chows = chows.tally.values.sum { |count| count / 2 }
        yaku[double_chows == 2 ? :two_double_chows : :double_chow] = double_chows == 2 ? 3 : 1 if closed && double_chows.positive?
        [31, 32, 33].each { |kind| yaku[[:dragon, kind].freeze] = 1 if triplets.include?(kind) }
        yaku[:seat_wind] = 1 if triplets.include?(seat)
        yaku[:round_wind] = 1 if triplets.include?(round)
        yaku[:all_pungs] = 2 if pungs.length == 4
        yaku[:three_concealed_pungs] = 2 if concealed_pungs.length >= 3
        yaku[:three_kongs] = 2 if kongs == 3
        yaku[:small_three_dragons] = 2 if (triplets & [31, 32, 33]).length == 2 && form.pair >= 31
        yaku[:mixed_triple_chow] = closed ? 2 : 1 if (0..6).any? { |start| [start, start + 9, start + 18].all? { |kind| chows.include?(kind) } }
        yaku[:mixed_triple_pung] = 2 if (0..8).any? { |rank| [rank, rank + 9, rank + 18].all? { |kind| triplets.include?(kind) } }
        yaku[:pure_straight] = closed ? 2 : 1 if (0..2).any? { |suit| [0, 3, 6].all? { |offset| chows.include?(suit * 9 + offset) } }
        outside = sets.all? { |group| Hand.tiles_for(group).any? { |kind| Tiles.terminal_or_honor?(kind) } } && Tiles.terminal_or_honor?(form.pair)
        if outside && !chows.empty?
          yaku[honors ? :mixed_outside : :pure_outside] = honors ? (closed ? 2 : 1) : (closed ? 3 : 2)
        end
      end
      yaku[:terminals_and_honors] = 2 if all.all? { |kind| Tiles.terminal_or_honor?(kind) }
      if suits.length == 1
        yaku[honors ? :half_flush : :full_flush] = honors ? (closed ? 3 : 2) : (closed ? 6 : 5)
      end
      return nil if yaku.empty?
      yaku[:dora] = dora if dora.positive?
      fu = form.type == :seven_pairs ? 25 : minipoints(form, placement, wait, melds, closed, self_draw, seat, round, yaku.key?(:pinfu))
      Result.new(han: yaku.values.sum, fu: fu, yakuman: 0, yaku: yaku.freeze, form: form, wait: wait).freeze
    end

    def minipoints(form, placement, wait, melds, closed, self_draw, seat, round, pinfu)
      return 20 if pinfu && self_draw
      points = 20
      points += 10 if closed && !self_draw
      points += 2 if self_draw
      # EMA 2025: a pair which is both seat and round wind gives two fu.
      points += 2 if form.pair >= 31 || [seat, round].include?(form.pair)
      points += 2 if %i[pair closed edge].include?(wait)
      form.groups.each_with_index do |(type, kind), index|
        next if type == :chow
        concealed = !melds[index]&.[](2) && (self_draw || index != placement)
        value = 2 * (Tiles.terminal_or_honor?(kind) ? 2 : 1) * (concealed ? 2 : 1) * (type == :kong ? 4 : 1)
        points += value
      end
      points = 30 if points == 20
      ((points + 9) / 10) * 10
    end

    def base_points(result)
      return 8000 * result.yakuman if result.yakuman.positive?
      han, fu = result.han, result.fu
      return 8000 if han >= 13
      return 6000 if han >= 11
      return 4000 if han >= 8
      return 3000 if han >= 6
      return 2000 if han >= 5 || [[3, 60], [4, 30]].include?([han, fu])
      [fu * 2 ** (han + 2), 2000].min
    end
    private_class_method :placements, :evaluate, :minipoints, :base_points
  end
end
