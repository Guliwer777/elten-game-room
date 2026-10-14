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

    def self.build(seeds:, players_per_match:, round_number:)
      unless seeds.is_a?(Array) && seeds.size.between?(2, 256) &&
          players_per_match.is_a?(Integer) && players_per_match.between?(2, 8) &&
          seeds.size >= players_per_match && (seeds.size - 1) % (players_per_match - 1) == 0 &&
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
      generation = Digest::SHA256.hexdigest(JSON.generate(['knockout-round-v1', seeds, players_per_match, round_number]))
      # The first explicitly seeded units receive byes. No synthetic match or
      # win is recorded for them, and no absent participant is invented.
      bye_count = seeds.size % players_per_match
      byes = seeds.take(bye_count)
      matches = seeds.drop(bye_count).each_slice(players_per_match).map.with_index do |participants, i|
        {'id' => "#{generation}:#{i + 1}", 'participants' => participants}
      end
      freeze_copy({'generation' => generation, 'round' => round_number, 'seeds' => seeds,
        'players_per_match' => players_per_match, 'byes' => byes, 'matches' => matches,
        'dispatch_allowed' => false})
    end

    def self.progress(seeds:, players_per_match:, round_number:, results:)
      plan = build(seeds: seeds, players_per_match: players_per_match, round_number: round_number)
      Standings.calculate(units: seeds, results: results)
      index = plan['matches'].to_h { |match| [match['id'], match['participants']] }
      unless results.all? { |result| index[result['id']] == result['participants'] }
        raise Publication::Invalid, :result_outside_knockout_plan
      end
      missing = index.keys - results.map { |result| result['id'] }
      unresolved = results.select { |result| result['winners'].size != 1 }.map { |result| result['id'] }
      next_seeds, champion = [], nil
      state = if !missing.empty?
        'awaiting_results'
      elsif !unresolved.empty?
        'tie_requires_resolution'
      else
        by_id = results.to_h { |result| [result['id'], result['winners'].first] }
        next_seeds = plan['byes'] + plan['matches'].map { |match| by_id.fetch(match['id']) }
        champion = next_seeds.first if next_seeds.size == 1
        champion ? 'completed' : 'ready_next_round'
      end
      freeze_copy({'state' => state, 'plan' => plan, 'missing_matches' => missing,
        'unresolved_matches' => unresolved, 'next_seeds' => next_seeds, 'champion' => champion})
    end

    def self.freeze_copy(value)
      Data.freeze_tree(Data.copy(value, max_bytes: 524_288, max_nodes: 32_768, max_depth: 10))
    end
    private_class_method :freeze_copy
  end
end
