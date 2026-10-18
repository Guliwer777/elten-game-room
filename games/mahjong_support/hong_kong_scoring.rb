# frozen_string_literal: true
require_relative 'hand'

module GameRoomMahjong
  module HongKongScoring
    Result = Struct.new(:fan, :patterns, :form, keyword_init: true)
    module_function

    # Explicit Clear Chapter profile: 3 fan minimum, eight-fan payment cap.
    # Fan conversion/payout follows the Mahjong 4 Friends published profile.
    # Flower/season sets replace their own-seat award rather than counting twice.
    def score(concealed:, winning_tile:, melds: [], self_draw: false,
        seat_wind: 27, round_wind: 27, flowers: [], minimum: 3, flags: {})
      Tiles.validate_kind(winning_tile, bonuses: false)
      unless concealed.is_a?(Array) && concealed.include?(winning_tile) && seat_wind.is_a?(Integer) && round_wind.is_a?(Integer) &&
          [27, 28, 29, 30].include?(seat_wind) && [27, 28, 29, 30].include?(round_wind) &&
          [true, false].include?(self_draw) && minimum.is_a?(Integer) && minimum.between?(0, 8) &&
          flowers.is_a?(Array) && flowers.uniq.length == flowers.length && flowers.all? { |kind| kind.is_a?(Integer) && kind.between?(34, 41) } &&
          flags.is_a?(Hash) && (flags.keys - %i[last_draw last_discard replacement robbing_kong heavenly earthly]).empty? &&
          flags.values.all? { |value| value == true || value == false }
        raise ArgumentError, 'Invalid Hong Kong scoring context'
      end
      unless melds.is_a?(Array) && melds.all? { |meld| meld.is_a?(Array) && meld.length == 3 && [true, false].include?(meld[2]) && (meld[2] || meld[0] == :kong) }
        raise ArgumentError, 'Invalid Hong Kong meld exposure'
      end
      if flags[:last_draw] && !self_draw || flags[:last_discard] && self_draw || flags[:replacement] && !self_draw || flags[:robbing_kong] && self_draw
        raise ArgumentError, 'Inconsistent Hong Kong win context'
      end
      raw = melds.map { |meld| meld.first(2) }
      forms = Hand.forms(concealed, melds: raw, split_quads: true)
      all = concealed + raw.flat_map { |meld| Hand.tiles_for(meld) }
      closed = melds.none? { |meld| meld[2] }
      candidates = forms.filter_map do |form|
        patterns = {}
        pungs = form.groups.select { |type, _kind| type != :chow }.map(&:last)
        winds = (pungs & [27, 28, 29, 30]).length
        dragons = (pungs & [31, 32, 33]).length
        suits = all.select { |kind| kind < 27 }.map { |kind| kind / 9 }.uniq
        honors = all.any? { |kind| kind >= 27 }
        special = {}
        special[:thirteen_orphans] = 13 if form.type == :thirteen_orphans
        special[:big_four_winds] = 15 if winds == 4
        special[:small_four_winds] = 10 if winds == 3 && form.pair&.between?(27, 30)
        special[:all_honors] = 10 if suits.empty?
        special[:all_terminals] = 10 if all.all? { |kind| kind < 27 && [0, 8].include?(kind % 9) }
        special[:four_kongs] = 18 if form.groups.count { |type, _kind| type == :kong } == 4
        special[:heavenly_hand] = 10 if flags[:heavenly] && self_draw && closed && seat_wind == 27
        special[:earthly_hand] = 10 if flags[:earthly] && !self_draw && closed && seat_wind != 27
        if melds.empty? && suits.length == 1 && !honors
          before = concealed.dup
          before.delete_at(before.index(winning_tile))
          counts = before.tally
          base = suits.first * 9
          special[:nine_gates] = 15 if (0...9).all? { |rank| counts.fetch(base + rank, 0) == ([0, 8].include?(rank) ? 3 : 1) }
        end
        if special.empty?
          patterns[:seven_pairs] = 4 if form.type == :seven_pairs
          patterns[:all_chows] = 1 if form.type == :standard && form.groups.all? { |type, _kind| type == :chow }
          patterns[:all_pungs] = 3 if pungs.length == 4
          patterns[:half_flush] = 3 if suits.length == 1 && honors
          patterns[:full_flush] = 7 if suits.length == 1 && !honors
          # Little/Big Dragons include the component dragon-pung fan.
          if dragons == 3
            patterns[:big_three_dragons] = 8
          elsif dragons == 2 && form.pair&.between?(31, 33)
            patterns[:small_three_dragons] = 5
          else
            patterns[:dragon_pungs] = dragons if dragons.positive?
          end
          patterns[:seat_wind] = 1 if pungs.include?(seat_wind)
          patterns[:round_wind] = 1 if pungs.include?(round_wind)
          patterns[:self_draw] = 1 if self_draw
          patterns[:no_flowers] = 1 if flowers.empty?
          [34, 38].each do |start|
            family = flowers.select { |kind| kind.between?(start, start + 3) }
            award = family.length == 4 ? 2 : family.include?(start + seat_wind - 27) ? 1 : 0
            patterns[start == 34 ? :flowers : :seasons] = award if award.positive?
          end
          %i[last_draw last_discard replacement robbing_kong].each { |flag| patterns[flag] = 1 if flags[flag] }
        else
          # Limit patterns do not acquire incidental lower-valued fan.
          key, value = special.max_by { |_key, points| points }
          patterns[key] = value
        end
        fan = patterns.values.sum
        Result.new(fan: fan, patterns: patterns.freeze, form: form).freeze if fan >= minimum
      end
      candidates.max_by(&:fan)
    end
  end
end
