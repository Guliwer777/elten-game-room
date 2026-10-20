# frozen_string_literal: true
require_relative 'chinese_deal'

module GameRoomMahjong
  module MCRDeal
    module_function
    # MCR 3.5.7.5-6 / 3.6.8: supplements consume the wall's back.
    def from_wall(wall, dealer: 0)
      ChineseDeal.from_wall(wall, dealer: dealer)
    end
    def shuffled(seed:, dealer: 0)
      ChineseDeal.shuffled(seed: seed, dealer: dealer)
    end
  end
end
