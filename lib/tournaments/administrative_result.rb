# encoding: UTF-8
require_relative 'publication'

module GameRoomTournaments
  # Organizer-owned places, never a fabricated replay or a game-specific
  # continuation rule. Games only declare their optional small-point units.
  module AdministrativeResult
    module_function
    def build(units:, places: nil, forfeits: [], scores: nil, policy: nil, all_zero: false)
      unless units.is_a?(Array) && units.size.between?(2, 8) && units.uniq.size == units.size && [true,false].include?(all_zero)
        raise Publication::Invalid, :invalid_administrative_result
      end
      units.each { |unit| Publication::Data.text!(unit, bytes: 256) }
      if all_zero
        raise Publication::Invalid, :invalid_administrative_result unless places.nil? && scores.nil? && forfeits == []
        return Publication::Data.freeze_tree({'participants'=>units.sort, 'winners'=>[], 'draw'=>false,
          'scores'=>nil, 'event_count'=>0, 'resolution'=>'all_zero'})
      end
      unless places.is_a?(Array) && !places.empty? && places.all? { |group| group.is_a?(Array) && !group.empty? && (group - units).empty? } &&
          places.flatten.size == units.size && places.flatten.sort == units.sort &&
          forfeits.is_a?(Array) && forfeits.uniq.size == forfeits.size && (forfeits - units).empty? &&
          (places.first & forfeits).empty?
        raise Publication::Invalid, :invalid_administrative_result
      end
      if policy
        unless policy.is_a?(Hash) && %w[higher lower].include?(policy[:order]) &&
            scores.is_a?(Hash) && scores.keys.sort == units.sort && scores.values.all? { |score| numeric?(score) }
          raise Publication::Invalid, :invalid_administrative_scores
        end
      elsif !scores.nil?
        raise Publication::Invalid, :invalid_administrative_scores
      end
      draw = places.first.size == units.size
      value = {'participants'=>units.sort, 'winners'=>draw ? [] : places.first.sort, 'draw'=>draw,
        'scores'=>scores && scores.sort.to_h, 'event_count'=>0, 'places'=>places.map(&:sort),
        'forfeits'=>forfeits.sort, 'resolution'=>'administrative'}
      value['score_order'] = policy[:order] if policy
      Publication::Data.freeze_tree(Publication::Data.copy(value))
    end

    def numeric?(value)
      (value.is_a?(Integer) || value.is_a?(Float) && value.finite?) && value.abs <= 1_000_000_000
    end

    def suggestions(units:, forfeits:, policy:)
      return nil unless policy
      units.to_h { |unit| [unit, policy.fetch(forfeits.include?(unit) ? :loser : :winner)] }
    end
  end
end
