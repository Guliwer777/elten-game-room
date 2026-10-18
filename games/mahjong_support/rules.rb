# frozen_string_literal: true

module GameRoomMahjong
  # Profiles describe actual occupied seats, including computer controllers.
  # Two human accounts do not silently turn a four-seat game into a new ruleset.
  module Rules
    VARIANTS = %w[solitaire hong_kong riichi mcr].freeze
    module_function

    def normalize(options)
      raise ArgumentError, 'Mahjong options must be a hash' unless options.is_a?(Hash)
      variant = options.fetch('variant', 'solitaire')
      raise ArgumentError, 'Unknown mahjong variant' unless VARIANTS.include?(variant)
      seats = options.fetch('seats', 4)
      seats = 1 if variant == 'solitaire'
      allowed = variant == 'solitaire' ? [1] : variant == 'riichi' ? [3, 4] : [4]
      raise ArgumentError, 'Unsupported mahjong seat count' unless seats.is_a?(Integer) && allowed.include?(seats)
      { 'variant' => variant, 'seats' => seats }.freeze
    end

    def allowed_seats(variant)
      raise ArgumentError, 'Unknown mahjong variant' unless VARIANTS.include?(variant)
      variant == 'solitaire' ? [1] : variant == 'riichi' ? [3, 4] : [4]
    end

    def bonuses?(options)
      %w[solitaire hong_kong mcr].include?(normalize(options)['variant'])
    end

    def sanma?(options)
      profile = normalize(options)
      profile['variant'] == 'riichi' && profile['seats'] == 3
    end

    def missing_seats(options, human_count)
      profile = normalize(options)
      unless human_count.is_a?(Integer) && human_count.between?(1, profile['seats'])
        raise ArgumentError, 'Invalid number of human players'
      end
      profile['seats'] - human_count
    end
  end
end
