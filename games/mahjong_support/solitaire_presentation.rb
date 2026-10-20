# frozen_string_literal: true
require_relative 'tile_labels'
require_relative '../base'

module GameRoomGames
  using GameRoomLocalization::Translations
  module MahjongSolitairePresentation
    def surface_spec(replay, viewer)
      state = replay.state
      board = state[:board]
      unless board
        return solitaire_information('mahjong-preparing', _('Mahjong'), _('Preparing the mahjong solitaire puzzle.'))
      end
      parts = []
      editable = !replay.finished? && same_user?(replay.players.first, viewer)
      unless board.remaining.empty?
        layers = board.positions.map(&:level).uniq.sort.map do |level|
          positions = board.positions.select { |position| position.level == level }
          rows, columns = positions.map(&:y).uniq.sort, positions.map(&:x).uniq.sort
          cells = Array.new(rows.length) { Array.new(columns.length) }
          board.positions.each_with_index do |position, slot|
            next unless position.level == level && board.remaining.include?(slot)
            covered = board.covered?(slot)
            kind = GameRoomMahjong::Tiles.kind(board.tiles.fetch(slot))
            match_key = kind.between?(34, 37) ? 'flowers' : kind.between?(38, 41) ? 'seasons' : kind.to_s
            cells[rows.index(position.y)][columns.index(position.x)] = GameSurfaces::LayeredTileCell.new(
              id: slot.to_s, label: solitaire_slot_label(board, slot), match_key: covered ? nil : match_key,
              selectable: !covered && board.free?(slot))
          end
          GameSurfaces::LayeredTileLayer.new(number: level + 1, cells: cells)
        end
        parts << solitaire_part('board', GameSurfaces::LayeredTileBoardSpec.new(header: _('Tiles in the layout'),
          layers: layers, epoch: [state[:session_id], state[:turn], replay.players].freeze,
          question_id: "mahjong-pairs:#{state[:turn]}", editable: editable))
      end
      parts << solitaire_part('status', solitaire_information('mahjong-status', _('Mahjong'), result_text(replay))) if replay.finished?
      if editable
        commands = []
        commands << GameSurfaces::Command.new(id: 'undo', label: GameRoomContent.utf8(_('Undo the last pair')),
          payload: {'turn'=>state[:turn]}) unless state[:moves].empty?
        commands << GameSurfaces::Command.new(id: 'surrender', label: GameRoomContent.utf8(_('End this puzzle')),
          payload: {'turn'=>state[:turn]})
        parts << solitaire_part('commands', GameSurfaces::CommandPanelSpec.new(commands: commands))
      end
      parts << solitaire_part('progress', solitaire_information('mahjong-progress', _('Progress'),
        _('%{pairs} pairs removed; %{tiles} tiles remaining.') % {pairs: state[:moves].length, tiles: board.remaining.length}))
      GameSurfaces::CompositeSpec.new(parts: parts)
    end

    def custom_game_shortcuts(replay, _viewer)
      board = replay&.state&.dig(:board)
      return [] unless board && !board.remaining.empty?
      board.positions.map(&:level).uniq.sort.map do |level|
        surface_shortcut(key: (level + 1).to_s, label: _('switch to layer %{layer}') % {layer: level + 1},
          command: 'tile_layer', payload: {'layer'=>level + 1})
      end + [surface_shortcut(key: 'd', label: _('read the current tile coordinates'), command: 'tile_coordinates')]
    end

    private

    def solitaire_part(id, surface)
      GameSurfaces::SurfacePart.new(id: id, surface: surface)
    end

    def solitaire_information(id, title, text)
      GameSurfaces::QuestionSpec.new(id: id, prompt: GameRoomContent.utf8(title), mode: :information,
        value: GameRoomContent.utf8(text), read_only: true)
    end

    def solitaire_slot_label(board, slot)
      return _('Covered tile') if board.covered?(slot)
      sides = board.open_sides(slot)
      status = if sides.length == 2
        _('available from both sides')
      elsif sides == [:left]
        _('available from the left')
      elsif sides == [:right]
        _('available from the right')
      else
        _('blocked on both sides')
      end
      GameRoomContent.utf8(_('%{tile}: %{status}') % {tile: GameRoomMahjong::TileLabels.label(board.tiles.fetch(slot)), status: status})
    end
  end
end
