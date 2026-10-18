# frozen_string_literal: true
require_relative 'table_round'
require_relative 'mcr_deal'
require_relative 'hong_kong_deal'
require_relative 'riichi_deal'

module GameRoomMahjong
  # Pure whole-match bookkeeping. The session adapter owns each hand number
  # and must persist its next deal/ready barrier through the ordinary executor.
  class MatchState
    attr_reader :variant, :seats, :winds, :points, :initial_points, :sticks,
      :dealer, :rotations, :honba, :hand_number

    def initialize(variant:, seats: 4, winds: nil, points: nil, initial_points: nil,
        sticks: 0, dealer: 0, rotations: 0, honba: 0, hand_number: 0)
      winds ||= variant == 'riichi' ? 2 : 4
      unless %w[mcr hong_kong riichi].include?(variant) && seats.is_a?(Integer) &&
          (variant == 'riichi' ? [3, 4].include?(seats) : seats == 4) &&
          winds.is_a?(Integer) && winds.between?(1, 4) && dealer.is_a?(Integer) && dealer.between?(0, seats - 1) &&
          rotations.is_a?(Integer) && rotations.between?(0, seats * winds) &&
          honba.is_a?(Integer) && honba.between?(0, 1000) && sticks.is_a?(Integer) && sticks.between?(0, 1_000_000) &&
          hand_number.is_a?(Integer) && hand_number >= 0 && (variant == 'riichi' || honba.zero? && sticks.zero?)
        raise ArgumentError, 'Invalid mahjong match state'
      end
      points ||= Array.new(seats, variant == 'riichi' ? 30000 : 0)
      initial_points ||= points
      unless [points, initial_points].all? { |values| values.is_a?(Array) && values.length == seats && values.all? { |value| value.is_a?(Integer) } }
        raise ArgumentError, 'Invalid match points'
      end
      @variant, @seats, @winds = variant.dup.freeze, seats, winds
      @points, @initial_points = points.dup.freeze, initial_points.dup.freeze
      @sticks, @dealer, @rotations, @honba, @hand_number = sticks, dealer, rotations, honba, hand_number
      freeze
    end

    def finished?; rotations == seats * winds; end
    def round_wind; 27 + [rotations / seats, winds - 1].min; end
    def scores; points.each_with_index.map { |value, seat| value - initial_points[seat] }.freeze; end

    def next_round(seed:)
      raise ArgumentError, 'The mahjong match is finished' if finished?
      flow = case variant
      when 'mcr' then MCRDeal.shuffled(seed: seed, dealer: dealer)
      when 'hong_kong' then HongKongDeal.shuffled(seed: seed, dealer: dealer)
      else RiichiDeal.shuffled(seed: seed, seats: seats, dealer: dealer)
      end
      ledger = variant == 'riichi' ? RiichiState.new(points: points, sticks: sticks) : nil
      TableRound.new(flow: flow, variant: variant, dealer: dealer, round_wind: round_wind,
        honba: honba, riichi_state: ledger)
    end

    def advance(round:, hand_number:)
      unless !finished? && hand_number.is_a?(Integer) && hand_number == @hand_number + 1 &&
          round.is_a?(TableRound) && round.finished? && round.result && round.variant == variant &&
          round.flow.hands.length == seats && round.dealer == dealer && round.round_wind == round_wind && round.honba == honba
        raise ArgumentError, 'Finished round does not belong to this match boundary'
      end
      result = round.result
      if variant == 'riichi'
        unless round.riichi_state.starting_points == points && round.riichi_outcome
          raise ArgumentError, 'Round ledger does not start at the match balance'
        end
        next_points, next_sticks = round.riichi_outcome.points, round.riichi_outcome.sticks
      else
        next_points = points.each_with_index.map { |value, seat| value + result.payments.fetch(seat) }
        next_sticks = 0
      end
      unless next_points.sum + next_sticks * 1000 == points.sum + sticks * 1000
        raise ArgumentError, 'Match points and outstanding deposits do not balance'
      end
      repeat = if variant == 'mcr'
        false
      elsif variant == 'hong_kong'
        result.draw? || result.winner == dealer
      else
        result.draw? ? result.tenpai.fetch(dealer) : result.winner == dealer
      end
      next_honba = 0
      next_honba = honba + 1 if variant == 'riichi' && (result.draw? || repeat)
      self.class.new(variant: variant, seats: seats, winds: winds, points: next_points, initial_points: initial_points,
        sticks: next_sticks, dealer: repeat ? dealer : (dealer + 1) % seats,
        rotations: rotations + (repeat ? 0 : 1), honba: next_honba, hand_number: hand_number)
    end
  end
end
