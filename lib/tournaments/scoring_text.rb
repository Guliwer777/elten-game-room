require_relative '../game_room_localization'
require_relative '../game_content'

module GameRoomTournaments
  module ScoringText
    DEFAULT = 'Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents.'.freeze

    def self.display
      GameRoomContent.utf8(GameRoomLocalization.translate('Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents.'))
    end

    def self.notes(value)
      value = GameRoomContent.utf8(value)
      GameRoomLocalization.translated_variants(DEFAULT).include?(value) ? '' : value
    end
  end
end
