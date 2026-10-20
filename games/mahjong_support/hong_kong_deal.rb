# frozen_string_literal: true
require_relative 'chinese_deal'

module GameRoomMahjong
  module HongKongDeal
    module_function
    # Explicit no-reserved-dead-wall HK preset; supplements use the back.
    def from_wall(wall, dealer: 0)
      ChineseDeal.from_wall(wall, dealer: dealer)
    end
    def shuffled(seed:, dealer: 0)
      ChineseDeal.shuffled(seed: seed, dealer: dealer)
    end
  end
end
