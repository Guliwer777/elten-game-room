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
      lines = [_('Current value: %{count} %{unit}.') %
        {count: ordinary.sum(&:points), unit: unit}]
      ordinary.each { |item| lines << mahjong_bonus_line(item, unit) }
      if round.variant == 'mcr'
        lines << _('Flowers: %{count} extra fan, outside the minimum of 8.') % {count: flowers.sum(&:points)}
      elsif round.riichi_state
        dora = GameRoomMahjong::RiichiDeal.dora_count(round.flow, winner: own, include_ura: false)
        lines << _('Dora: %{count}, separate from yaku.') % {count: dora}
      end
      GameRoomContent.utf8(lines.join(' '))
    end

    def mahjong_bonus_line(item, unit)
      tile = item.type != :concealed_pungs && item.kind && GameRoomMahjong::TileLabels.label(item.kind < 34 ? item.kind * 4 : 136 + item.kind - 34)
      label = case item.type
      when :concealed_pungs then _('%{count} concealed pungs') % {count: item.kind}
      when :dragon then _('Dragon pung or kong: %{tile}') % {tile: tile}
      when :seat_wind then _('Your wind pung or kong: %{tile}') % {tile: tile}
      when :round_wind then _('Round wind pung or kong: %{tile}') % {tile: tile}
      when :own_bonus then _('Your bonus tile: %{tile}') % {tile: tile}
      when :extra_flower then _('Bonus tile: %{tile}') % {tile: tile}
      when :flower_set then _('All four flowers')
      when :season_set then _('All four seasons')
      when :riichi then item.points == 2 ? _('Double riichi') : _('Riichi')
      end
      format = item.conditional ? _('%{reason}: %{count} %{unit}, if you retain the concealed set.') : _('%{reason}: %{count} %{unit}.')
      format % {reason: label, count: item.points, unit: unit}
    end
  end
end
