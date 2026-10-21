# frozen_string_literal: true
require_relative 'fan_progress'

module GameRoomGames
  using GameRoomLocalization::Translations

  module MahjongFanAnnouncements
    private

    def mahjong_progress_text(round, own)
      items = GameRoomMahjong::FanProgress.items(round, own)
      ordinary, flowers = items.partition { |item| item.type != :extra_flower }
      unit = round.variant == 'riichi' ? _('han') : _('fan')
      lines = [_('Basic bonuses from your current sets and declarations: %{count} %{unit}.') %
        {count: ordinary.sum(&:points), unit: unit}]
      ordinary.each { |item| lines << mahjong_bonus_line(item, unit) }
      if round.variant == 'mcr'
        lines << _('Flowers and seasons: %{count} extra fan; these do not count towards the minimum of 8.') % {count: flowers.sum(&:points)}
        flowers.each { |item| lines << mahjong_bonus_line(item, _('fan')) }
      elsif round.variant == 'hong_kong' && round.flow.flowers.fetch(own).empty?
        lines << _('No flowers or seasons currently: a possible extra 1 fan, not included above; drawing a bonus tile removes it.')
      elsif round.riichi_state
        dora = GameRoomMahjong::RiichiDeal.dora_count(round.flow, winner: own, include_ura: false)
        lines << _('Visible dora in your hand: %{count}; not included above. Dora require a winning hand with yaku.') % {count: dora}
      end
      lines << _('This is a basic subtotal, not the final hand value. Retain concealed triplets as sets; complete-hand patterns may replace these bonuses.')
      GameRoomContent.utf8(lines.join(' '))
    end

    def mahjong_bonus_line(item, unit)
      tile = item.kind && GameRoomMahjong::TileLabels.label(item.kind < 34 ? item.kind * 4 : 136 + item.kind - 34)
      label = case item.type
      when :dragon then _('Dragon pung or kong: %{tile}') % {tile: tile}
      when :seat_wind then _('Your wind pung or kong: %{tile}') % {tile: tile}
      when :round_wind then _('Round wind pung or kong: %{tile}') % {tile: tile}
      when :own_bonus then _('Your bonus tile: %{tile}') % {tile: tile}
      when :extra_flower then _('Bonus tile: %{tile}') % {tile: tile}
      when :flower_set then _('All four flowers')
      when :season_set then _('All four seasons')
      when :riichi then item.points == 2 ? _('Double riichi') : _('Riichi')
      end
      _('%{reason}: %{count} %{unit}.') % {reason: label, count: item.points, unit: unit}
    end
  end
end
