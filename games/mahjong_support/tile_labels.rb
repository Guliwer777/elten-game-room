# frozen_string_literal: true
require_relative 'tiles'
require_relative '../../lib/game_content'
require_relative '../../lib/game_room_localization'

module GameRoomMahjong
  using GameRoomLocalization::Translations
  module TileLabels
    module_function

    def label(tile)
      kind = Tiles.kind(tile)
      text = if kind < 27
        suit = [_('Characters'), _('Dots'), _('Bamboo')].fetch(kind / 9)
        _('%{number} of %{suit}') % {number: kind % 9 + 1, suit: suit}
      else
        [_('East wind'), _('South wind'), _('West wind'), _('North wind'),
          _('White dragon'), _('Green dragon'), _('Red dragon'),
          _('Plum flower'), _('Orchid flower'), _('Chrysanthemum flower'), _('Bamboo flower'),
          _('Spring'), _('Summer'), _('Autumn'), _('Winter')].fetch(kind - 27)
      end
      GameRoomContent.utf8(text)
    end
  end
end
