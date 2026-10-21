# frozen_string_literal: true
require_relative 'fan_announcements'
module GameRoomGames
  using GameRoomLocalization::Translations

  module MahjongInformationShortcuts
    include MahjongFanAnnouncements
    private

    def mahjong_information_shortcuts(replay, viewer)
      round = replay.state.fetch(:round)
      own = replay.players.index { |player| same_user?(player, viewer) }
      shortcuts = [announcement_shortcut(key: 'r', label: _('read the hand situation'),
        message: mahjong_situation_text(replay, own))]
      shortcuts << GameShortcut.new(key: 'u', modifiers: [:shift], kind: :announcement,
        label: _('read other players exposed sets'), message: mahjong_melds_text(replay, own, others: true))
      if own
        shortcuts << announcement_shortcut(key: 'u', label: _('read your exposed sets'),
          message: mahjong_melds_text(replay, own, others: false))
        shortcuts << announcement_shortcut(key: 'w', label: _('read your hand value and basic bonuses'),
          message: mahjong_hand_value_text(replay, own))
        if round.riichi_state
          shortcuts << announcement_shortcut(key: 'i', label: _('read dora and your Riichi status'),
            message: mahjong_riichi_text(replay, own))
        end
      end
      shortcuts
    end

    def mahjong_hand_value_text(replay, own)
      round = replay.state.fetch(:round)
      value = mahjong_value_text(round, own)
      return value if round.finished? || replay.state.fetch(:profile).fetch('fan_progress', 'yes') == 'no'
      value + ' ' + mahjong_progress_text(round, own)
    end

    def mahjong_melds_text(replay, own, others:)
      flow = replay.state.fetch(:round).flow
      lines = replay.players.each_index.filter_map do |seat|
        next if others ? seat == own : seat != own
        sets = flow.melds.fetch(seat).map do |meld|
          type = {chow: _('Chow'), pung: _('Pung'), kong: _('Kong')}.fetch(meld.fetch(:type))
          tiles = meld.fetch(:tiles).map { |tile| GameRoomMahjong::TileLabels.label(tile) }.join(', ')
          _('%{action}: %{tiles}') % {action: type, tiles: tiles}
        end
        text = sets.empty? ? _('No exposed sets.') : sets.join('; ')
        _('%{player}: %{tiles}') % {player: participant_name(replay.players.fetch(seat)), tiles: text}
      end
      lines.empty? ? _('No exposed sets.') : lines.join('. ')
    end

    def mahjong_situation_text(replay, own)
      round = replay.state.fetch(:round)
      lines = [_('Hand number: %{number}.') % {number: replay.state[:hand_number] || 1},
        _('Round wind: %{wind}.') % {wind: GameRoomMahjong::TileLabels.label(round.round_wind * 4)}]
      if own
        wind = 27 + (own - round.dealer) % replay.players.length
        lines << _('Your wind: %{wind}.') % {wind: GameRoomMahjong::TileLabels.label(wind * 4)}
      end
      lines << if round.finished?
        round.result && !round.result.draw? ? _('Winner: %{player}') % {player: participant_name(replay.players.fetch(round.result.winner))} : _('The hand ended in a draw.')
      elsif %i[reactions kong_reactions].include?(round.flow.phase)
        _('Waiting for responses from: %{players}.') % {players: round.window.pending.map { |seat| participant_name(replay.players.fetch(seat)) }.join(', ')}
      else
        _('%{player} is taking a turn.') % {player: participant_name(replay.players.fetch(round.flow.seat))}
      end
      lines.join(' ')
    end

    def mahjong_value_text(round, own)
      result = if round.finished?
        round.result if round.result && round.result.winner == own
      elsif (round.flow.phase == :discard && round.flow.seat == own && round.flow.last_draw) ||
          (%i[reactions kong_reactions].include?(round.flow.phase) && round.window&.pending&.include?(own) &&
            round.window.offers.fetch(own).include?([:win]))
        round.winning_result(own, include_ura: false)
      end
      return _('No legal win is available for your hand now; no final value can be given.') unless result
      score = result.score
      value = if round.variant == 'hong_kong'
        _('%{fan} fan') % {fan: score.fan}
      elsif round.variant == 'mcr'
        _('%{fan} fan; flower points: %{flowers}') % {fan: score.fan, flowers: score.flowers}
      elsif score.yakuman.positive?
        _('%{count} yakuman') % {count: score.yakuman}
      else
        _('%{han} han, %{fu} fu') % {han: score.han, fu: score.fu}
      end
      # An unsettled Riichi pot is not included in the scorer's base payments.
      pot = !round.finished? && round.riichi_state ? round.riichi_state.sticks * 1000 : 0
      text = _('%{value}. Points gained: %{points}.') % {value: value, points: result.payments.fetch(own) + pot}
      if !round.finished? && round.riichi_state && round.riichi_state.levels.fetch(own).positive?
        text += ' ' + _('Preview excludes hidden ura-dora; the final value may be higher.')
      end
      GameRoomContent.utf8(text)
    end

    def mahjong_riichi_text(replay, own)
      round = replay.state.fetch(:round)
      flow, ledger = round.flow, round.riichi_state
      indicators = flow.dora_indicators.map { |tile| GameRoomMahjong::TileLabels.label(tile) }
      dora = flow.dora_indicators.map do |tile|
        GameRoomMahjong::TileLabels.label(GameRoomMahjong::RiichiDeal.dora_kind(tile, sanma: replay.players.length == 3) * 4)
      end
      lines = indicators.empty? ? [_('No dora indicators.')] :
        [_('Dora indicators: %{tiles}.') % {tiles: indicators.join(', ')},
         _('Dora tiles: %{tiles}.') % {tiles: dora.join(', ')}]
      lines << _('Your dora: %{count}.') % {count: GameRoomMahjong::RiichiDeal.dora_count(flow, winner: own)}
      declarations = replay.players.each_index.filter_map do |seat|
        next if ledger.levels.fetch(seat).zero?
        text = ledger.levels.fetch(seat) == 2 ? _('%{player}: double riichi') : _('%{player}: riichi')
        text % {player: participant_name(replay.players.fetch(seat))}
      end
      lines << (declarations.empty? ? _('No Riichi declarations.') : declarations.join('; '))
      lines << _('Deposits on the table: %{count}.') % {count: ledger.sticks}
      lines << _('Honba: %{count}.') % {count: round.honba}
      temporary = round.furiten.fetch(own) || ledger.furiten.fetch(own)
      if round.finished?
        lines << _('The hand has ended.')
      elsif temporary
        lines << _('Furiten: winning on a discard is blocked; self-draw is still possible.')
      elsif flow.hands.fetch(own).length % 3 == 1
        melds = flow.melds.fetch(own).map { |meld| [meld[:type], meld[:first_kind]] }
        waits = GameRoomMahjong::Hand.waits(flow.hands.fetch(own).map { |tile| GameRoomMahjong::Tiles.kind(tile) }, melds: melds)
        discarded = flow.discard_history.select { |seat, _| seat == own }.map { |_, tile| GameRoomMahjong::Tiles.kind(tile) }
        lines << if (waits & discarded).empty?
          _('Furiten is not blocking a discard win; a complete hand with yaku is still required.')
        else
          _('Furiten: winning on a discard is blocked; self-draw is still possible.')
        end
      else
        lines << _('Discard-based furiten can be checked after your discard.')
      end
      GameRoomContent.utf8(lines.join(' '))
    end
  end
end
