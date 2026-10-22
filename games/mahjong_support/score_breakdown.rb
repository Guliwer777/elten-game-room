# encoding: UTF-8
# frozen_string_literal: true
module GameRoomGames
  using GameRoomLocalization::Translations

  # Explain only the components selected by the accepted scorer. The existing
  # localized rulebook owns pattern descriptions; no second scoring pass.
  module MahjongScoreBreakdown
    HK_ROWS = {self_draw: 0, all_chows: 1, seat_wind: 5, round_wind: 6,
      replacement: 7, robbing_kong: 8, last_draw: 9, last_discard: 10,
      no_flowers: 11, all_pungs: 16, half_flush: 17, seven_pairs: 18,
      small_three_dragons: 19, full_flush: 20, big_three_dragons: 21,
      small_four_winds: 22, all_honors: 23, all_terminals: 24,
      thirteen_orphans: 25, big_four_winds: 26, nine_gates: 27, four_kongs: 28}.freeze
    RIICHI_ROWS = %i[riichi double_riichi ippatsu concealed_self_draw all_simples dragon
      seat_wind round_wind last_draw last_discard replacement_draw robbing_kong pinfu
      double_chow two_double_chows seven_pairs all_pungs three_concealed_pungs
      three_kongs small_three_dragons mixed_triple_chow mixed_triple_pung pure_straight
      mixed_outside pure_outside terminals_and_honors half_flush full_flush].freeze
    YAKUMAN_ROWS = %i[thirteen_orphans four_concealed_pungs big_three_dragons big_four_winds
      small_four_winds all_honors all_terminals all_green four_kongs nine_gates].freeze

    private

    def mahjong_score_breakdown(round)
      score = round.result.score
      sections = localized_rule_sections || rule_sections
      if round.variant == 'mcr'
        rows = sections.select { |s| s.id.to_s.start_with?('table_mcr_fan_') }.flat_map(&:paragraphs)
        lines = [_('Hand: %{fan} fan. Flowers and seasons: %{flowers} extra fan. Total for payment: %{total} fan.') %
          {fan: score.fan, flowers: score.flowers, total: score.fan + score.flowers}]
        score.patterns.each do |pattern|
          row = rows.find { |text| text.match?(/\A- MCR #{pattern.id}:/) }
          reason = pattern.id == 57 && pattern.points == 6 ? _('Mixed exposed and concealed kongs') : row&.split(' — ', 2)&.last
          raise ArgumentError, 'Missing MCR score description' unless reason
          lines << _('%{reason}: %{count} %{unit}.') % {reason: reason.sub(/\.\z/, ''), count: pattern.points, unit: _('fan')}
        end
      else
        unit = round.variant == 'hong_kong' ? _('fan') : score.yakuman.positive? ? _('yakuman') : _('han')
        entries = round.variant == 'hong_kong' ? score.patterns : score.yaku
        lines = entries.flat_map { |key, points| mahjong_named_score_rows(sections, score, round.variant, key, points) }
        lines.map! { |reason, points| _('%{reason}: %{count} %{unit}.') % {reason: reason, count: points, unit: unit} }
      end
      GameRoomContent.utf8(lines.join("\n"))
    end

    def mahjong_named_score_rows(sections, score, variant, key, points)
      if variant == 'hong_kong'
        rows = sections.select { |s| s.id.to_s.start_with?('table_hk_fan_') }.flat_map(&:paragraphs)
        indices = if key == :dragon_pungs
          score.form.groups.filter_map { |type, kind| {33=>2, 32=>3, 31=>4}[kind] if type != :chow }
        elsif key == :flowers || key == :seasons
          [key == :flowers ? (points == 2 ? 14 : 12) : (points == 2 ? 15 : 13)]
        else
          [HK_ROWS.fetch(key)]
        end
        indices.map { |index| [rows.fetch(index).split(' — ', 2).last, key == :dragon_pungs ? 1 : points] }
      else
        return [[_('Dora'), points]] if key == :dora
        ids = score.yakuman.positive? ? YAKUMAN_ROWS : RIICHI_ROWS
        chapter = score.yakuman.positive? ? :table_riichi_yakuman : :table_yaku
        rows = sections.find { |s| s.id == chapter }.paragraphs.grep(/\A- /)
        index = ids.index(key.is_a?(Array) ? key.first : key)
        raise ArgumentError, 'Unknown Riichi score component' unless index
        row = rows.fetch(index).sub(/\A- /, '')
        row = row.split(' — ', 2).last if score.yakuman.positive?
        row += ' ' + GameRoomMahjong::TileLabels.label(key.last * 4) if key.is_a?(Array)
        [[row, points]]
      end
    end
  end
end
