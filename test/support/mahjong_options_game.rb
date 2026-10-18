require_relative '../../games/mahjong_support/options'

module MahjongOptionsTest
  class Game < GameRoomGames::Base
    include GameRoomGames::MahjongOptions
    def id; 'mahjong'; end
    def name; 'Mahjong'; end
    def supports_bots?; true; end
  end
end
