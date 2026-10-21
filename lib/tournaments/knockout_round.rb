require 'digest'
require 'json'
require_relative 'standings'

module GameRoomTournaments
  # Local candidate with explicit seed order, not a native table reservation.
  # One advancing unit per match; draws/shared wins require a separate decision.
  class KnockoutRound
    Data = Publication::Data

    def self.from_qualification(qualified:, seeds:, players_per_match:)
      unless seeds.is_a?(Array) && seeds.size == qualified.size &&
          seeds.uniq.size == seeds.size && (seeds - qualified).empty?
        raise Publication::Invalid, :invalid_qualification_seeding
      end
      build(seeds: seeds, players_per_match: players_per_match, round_number: 1)
    end

    def self.build(seeds:, players_per_match:, round_number:, bracket_groups: nil)
      unless seeds.is_a?(Array) && seeds.size.between?(2, 256) &&
          players_per_match.is_a?(Integer) && players_per_match.between?(2, 8) &&
          seeds.size >= players_per_match && (bracket_groups || (seeds.size - 1) % (players_per_match - 1) == 0) &&
          round_number.is_a?(Integer) && round_number.between?(1, 255)
        raise Publication::Invalid, :invalid_knockout_configuration
      end
      begin
        # Canonical account IDs may expand when Unicode names are lowercased;
        # use the standings unit bound, not the raw draft-name character bound.
        Standings.calculate(units: seeds, results: [])
        unless seeds.map(&:downcase).uniq.size == seeds.size &&
            seeds.none? { |unit| unit.match?(/\A[[:space:]]|[[:space:]]\z/) }
          raise Publication::Invalid, :invalid_knockout_configuration
        end
      rescue Publication::Invalid
        raise Publication::Invalid, :invalid_knockout_configuration
      end
      # The first explicitly seeded units receive byes. No synthetic match or
      # win is recorded for them, and no absent participant is invented.
      bye_count = seeds.size % players_per_match
      defaults = seeds.take(bye_count).map { |unit| [unit] } + seeds.drop(bye_count).each_slice(players_per_match).to_a
      explicit = !bracket_groups.nil? && bracket_groups != defaults
      if explicit
        unless bracket_groups.is_a?(Array) && bracket_groups.size.between?(1,256) && bracket_groups.all? { |group| group.is_a?(Array) &&
            [0,1,players_per_match].include?(group.size) } && bracket_groups.flatten == seeds &&
            bracket_groups.any? { |group| group.size == players_per_match }
          raise Publication::Invalid,:invalid_knockout_configuration
        end
      end
      groups = explicit ? bracket_groups : defaults
      byes = groups.select { |group| group.size == 1 }.flatten
      identity = explicit ? ['knockout-round-v2',seeds,players_per_match,round_number,groups] :
        ['knockout-round-v1',seeds,players_per_match,round_number]
      generation = Digest::SHA256.hexdigest(JSON.generate(identity))
      matches = groups.select { |group| group.size == players_per_match }.map.with_index do |participants, i|
        {'id' => "#{generation}:#{i + 1}", 'participants' => participants}
      end
      value={'generation' => generation, 'round' => round_number, 'seeds' => seeds,
        'players_per_match' => players_per_match, 'byes' => byes, 'matches' => matches,
        'dispatch_allowed' => false}
      value['bracket_groups'] = groups if explicit
      freeze_copy(value)
    end

    def self.from_metadata(metadata)
      build(seeds:metadata['seeds'],players_per_match:metadata['players_per_match'],round_number:metadata['round'],
        bracket_groups:metadata['bracket_groups'])
    end

    def self.progress(seeds:, players_per_match:, round_number:, results:, bracket_groups: nil)
      plan = build(seeds: seeds, players_per_match: players_per_match, round_number: round_number, bracket_groups:bracket_groups)
      Standings.calculate(units: seeds, results: results)
      index = plan['matches'].to_h { |match| [match['id'], match['participants']] }
      unless results.all? { |result| index[result['id']] == result['participants'] }
        raise Publication::Invalid, :result_outside_knockout_plan
      end
      missing = index.keys - results.map { |result| result['id'] }
      unresolved = results.select { |result| result['winners'].size != 1 && result['resolution'] != 'all_zero' }.map { |result| result['id'] }
      next_seeds, champion = [], nil
      state = if !missing.empty?
        'awaiting_results'
      elsif !unresolved.empty?
        'tie_requires_resolution'
      else
        by_id = results.to_h { |result| [result['id'], result['winners'].first] }
        slots = if plan['bracket_groups']
          plan['bracket_groups'].map do |group|
            group.empty? ? nil : group.size == 1 ? group.first : by_id.fetch(plan['matches'].find { |match| match['participants']==group }.fetch('id'))
          end
        else
          plan['byes'] + plan['matches'].map { |match| by_id.fetch(match['id']) }
        end
        next_seeds = slots.compact
        if next_seeds.size > 1 && (slots.include?(nil) || plan.key?('bracket_groups'))
          layout = advance_vacancies(slots, players_per_match, round_number+1)
          next_seeds = layout.fetch('seeds')
        end
        champion = next_seeds.first if next_seeds.size == 1
        next_seeds.size <= 1 ? 'completed' : 'ready_next_round'
      end
      value={'state' => state, 'plan' => plan, 'missing_matches' => missing,
        'unresolved_matches' => unresolved, 'next_seeds' => next_seeds, 'champion' => champion}
      value.merge!('next_bracket_groups'=>layout['groups'],'next_round'=>layout['round']) if defined?(layout) && layout
      freeze_copy(value)
    end

    def self.advance_vacancies(slots, count, round)
      singles=slots.take(slots.size % count).map { |unit| unit ? [unit] : [] }
      groups=singles+slots.drop(slots.size % count).each_slice(count).map(&:compact)
      unless groups.all? { |group| [0,1,count].include?(group.size) }
        raise Publication::Invalid,:invalid_knockout_configuration
      end
      byes=groups.select { |group| group.size==1 }.flatten
      matches=groups.select { |group| group.size==count }
      return advance_vacancies(groups.map(&:first),count,round+1) if matches.empty? && byes.size>1
      {'seeds'=>groups.flatten,'groups'=>groups,'round'=>round}
    end
    private_class_method :advance_vacancies

    def self.freeze_copy(value)
      Data.freeze_tree(Data.copy(value, max_bytes: 524_288, max_nodes: 32_768, max_depth: 10))
    end
    private_class_method :freeze_copy
  end
end
