# frozen_string_literal: true

module GameRoomDuckRacing
  module Cards
    Type = Data.define(:id, :reference, :english_name, :cost, :target, :gain, :effects)
    Copy = Data.define(:id, :type)
    Draw = Data.define(:cards, :next_serial)

    # References are the maintainer's selection numbers, not deck positions.
    # Keep this order stable: a saved seed must continue to draw the same types.
    TYPES = [
      [1, "mine", "Mine", 7, :square, 0, [[:move, -15]]],
      [2, "interested_help", "Interested help", 1, :opponent, 0, [[:steal_feathers, 3], [:move, 2]]],
      [3, "helix", "Helix", 7, :any, 0, [[:move, 4]]],
      [4, "hand_switch", "Hand switch", 2, :opponent, 0, [[:swap_hands]]],
      [5, "yellowbelly_die", "Yellowbelly die", 5, :opponent, 0, [[:die, 3, 2]]],
      [6, "challenge", "Challenge", 0, :opponent, 0, [[:duel]]],
      [7, "tar_stain", "Tar stain", 2, :square, 0, [[:steal_feathers, 4]]],
      [8, "soporific_pill", "Soporific pill", 10, :opponent, 0, [[:skip, 3]]],
      [9, "paid_service", "Paid service", 2, :opponent, 0, [[:steal_feathers, 4], [:move, 3]]],
      [10, "opportunistic_die", "Opportunistic die", 5, :self, 0, [[:die, 10, 2]]],
      [11, "investment", "Investment", 0, :square, 7, [[:move, 5]]],
      [23, "ejectable_seat", "Ejectable seat", 2, :square, 0, [[:random_move, 1, 2]]],
      [24, "withdrawal", "Withdrawal", 3, :any, 0, [[:move, -2]]],
      [25, "super_glue", "Super glue", 5, :square, 0, [[:skip, 3]]],
      [26, "long_absence", "Long absence", 7, :opponent, 0, [[:skip, 2]]],
      [27, "detour", "Detour", 5, :square, 0, [[:move, -4]]],
      [28, "guided_missile", "Guided missile", 12, :opponent, 0, [[:move, -10]]],
      [29, "super_challenge", "Super challenge", 0, :self, 0, [[:group_challenge]]],
      [30, "winning_die", "Winning die", 8, :self, 0, [[:die, 12, 3]]],
      [31, "shortness_of_breath", "Shortness of breath", 5, :any, 0, [[:move, -3]]],
      [32, "impulsion", "Impulsion", 3, :any, 0, [[:move, 2]]],
      [33, "taste_for_risk", "Taste for risk", 4, :self, 0, [[:random_move, 1, 10]]],
      [34, "home_made_bomb", "Home made bomb", 4, :opponent, 0, [[:random_move, 1, 8]]],
      [35, "sandwich", "Sandwich", 0, :self, 3, [[:skip, 1]]],
      [36, "counter_current", "Counter-current", 3, :square, 0, [[:move, -3]]],
      [37, "hand_mix", "Hand mix", 1, :self, 0, [[:pass_hands]]],
      [38, "card_rob", "Card rob", 3, :opponent, 0, [[:steal_cards, 1]]],
      [39, "planified_deal", "Planified deal", 0, :square, 0, [[:everyone_cards, 1]]],
      [40, "repairing_rest", "Repairing rest", 0, :self, 10, [[:skip, 3]]],
      [41, "curiosity", "Curiosity", 1, :self, 0, [[:quiz]]],
      [42, "tiny_recoil", "Tiny recoil", 0, :self, 2, [[:move, -2]]],
      [43, "good_draw", "Good draw", 3, :self, 0, [[:cards, 3]]],
      [44, "oil_stain", "Oil stain", 1, :square, 0, [[:steal_feathers, 2], [:move, -1]]],
      [45, "die_normalizing", "Die normalizing", 2, :any, 0, [[:die, 6, 0]]],
      [46, "altruism", "Altruism", 0, :square, 4, [[:move, 3]]],
      [47, "thick_die", "Thick die", 3, :square, 0, [[:die, 3, 2]]],
      [48, "golden_sleep", "Golden sleep", 0, :opponent, 0, [[:skip, 2], [:feathers, 6]]]
    ].map do |reference, id, name, cost, target, gain, effects|
      Type.new(id, reference, name, cost, target, gain, effects.each(&:freeze).freeze)
    end.freeze
    BY_ID = TYPES.to_h { |type| [type.id, type] }.freeze
    POOL = TYPES.map(&:id).freeze
    INITIAL_HAND_SIZE = 3

    module_function

    # The caller records the seed in the accepted move and retains next_serial
    # in replay state. There is no deck to deplete or replenish.
    def draw(count:, next_serial:, random:, eligible: POOL)
      raise ArgumentError, "Invalid draw count" unless count.is_a?(Integer) && count >= 0
      raise ArgumentError, "Invalid card serial" unless next_serial.is_a?(Integer) && next_serial >= 1
      raise ArgumentError, "Invalid card filter" unless eligible.is_a?(Array) && eligible.all? { |id| BY_ID.key?(id) }

      pool = POOL.select { |id| eligible.include?(id) }
      raise ArgumentError, "No eligible Duck Racing cards" if count > 0 && pool.empty?

      cards = Array.new(count) do |offset|
        type = pool.fetch(random.rand(pool.length))
        Copy.new("duck-card-#{next_serial + offset}".freeze, type)
      end.freeze
      Draw.new(cards, next_serial + count)
    end
  end
end
