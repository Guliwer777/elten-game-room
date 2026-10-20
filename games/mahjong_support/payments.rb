# frozen_string_literal: true

module GameRoomMahjong
  module Payments
    module_function

    # Pure settlement; no account names, UI, or network authority. Positive
    # values are received, negative values are paid, and every result sums to 0.
    def riichi(han:, fu:, winner:, dealer:, seats: 4, discarder: nil, honba: 0,
        yakuman: 0, kiriage: true)
      validate_seats(winner, dealer, seats, discarder)
      raise ArgumentError, 'Invalid riichi score' unless han.is_a?(Integer) && han.between?(0, 100) &&
        yakuman.is_a?(Integer) && yakuman.between?(0, 10) &&
        fu.is_a?(Integer) && (yakuman.positive? && fu.zero? || [20, 25].include?(fu) || fu.between?(30, 160) && fu % 10 == 0) &&
        honba.is_a?(Integer) && honba.between?(0, 1000)
      raise ArgumentError, 'A riichi win needs a yaku' if han.zero? && yakuman.zero?
      base = if yakuman.positive?
        8000 * yakuman
      elsif han >= 13 then 8000
      elsif han >= 11 then 6000
      elsif han >= 8 then 4000
      elsif han >= 6 then 3000
      elsif han >= 5 || kiriage && [ [3, 60], [4, 30] ].include?([han, fu]) then 2000
      else [fu * (2 ** (han + 2)), 2000].min
      end
      result = Array.new(seats, 0)
      if discarder
        amount = ceil100(base * (winner == dealer ? 6 : 4)) + 300 * honba
        result[discarder] -= amount
        result[winner] += amount
      else
        seats.times do |payer|
          next if payer == winner
          amount = ceil100(base * (winner == dealer || payer == dealer ? 2 : 1)) + 100 * honba
          result[payer] -= amount
          result[winner] += amount
        end
      end
      result.freeze
    end

    def mcr(fan:, flowers:, winner:, discarder: nil)
      validate_seats(winner, 0, 4, discarder)
      unless fan.is_a?(Integer) && fan.between?(8, 1000) && flowers.is_a?(Integer) && flowers.between?(0, 8)
        raise ArgumentError, 'MCR requires eight non-flower points'
      end
      value = fan + flowers
      result = Array.new(4, -8)
      result[winner] = 0
      if discarder
        result[discarder] -= value
      else
        4.times { |payer| result[payer] -= value unless payer == winner }
      end
      result[winner] = -result.sum
      result.freeze
    end

    def hong_kong(fan:, minimum:, winner:, discarder: nil)
      validate_seats(winner, 0, 4, discarder)
      unless fan.is_a?(Integer) && fan.between?(0, 100) && minimum.is_a?(Integer) && minimum.between?(0, 13) && fan >= minimum
        raise ArgumentError, 'Hong Kong hand does not meet the table minimum'
      end
      # Half-pay discards: discarder pays the full amount, the other two
      # opponents half each; on self-draw all three pay the full amount.
      base = [1, 2, 4, 8, 16, 24, 32, 48, 64].fetch([fan, 8].min)
      result = Array.new(4, 0)
      4.times do |payer|
        next if payer == winner
        amount = !discarder || payer == discarder ? base * 2 : base
        result[payer] -= amount
        result[winner] += amount
      end
      result.freeze
    end

    def riichi_draw(tenpai:, seats: 4)
      unless seats.is_a?(Integer) && [3, 4].include?(seats) && tenpai.is_a?(Array) && tenpai.length == seats && tenpai.all? { |value| value == true || value == false }
        raise ArgumentError, 'Invalid riichi tenpai declaration'
      end
      ready = tenpai.count(true)
      return Array.new(seats, 0).freeze if ready.zero? || ready == seats
      pool = seats == 3 ? 2000 : 3000
      tenpai.map { |value| value ? pool / ready : -pool / (seats - ready) }.freeze
    end

    def ceil100(value)
      ((value + 99) / 100) * 100
    end

    def validate_seats(winner, dealer, seats, discarder)
      unless seats.is_a?(Integer) && [3, 4].include?(seats) && [winner, dealer].all? { |seat| seat.is_a?(Integer) && seat.between?(0, seats - 1) } &&
          (discarder.nil? || discarder.is_a?(Integer) && discarder.between?(0, seats - 1) && discarder != winner)
        raise ArgumentError, 'Invalid mahjong settlement seats'
      end
    end
    private_class_method :validate_seats, :ceil100
  end
end
