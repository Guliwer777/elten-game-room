require_relative 'knockout_round'

module GameRoomTournaments
  # Sporting projection only. Decisive results retain their original match
  # identity; only unresolved matches receive new playable fixtures.
  module KnockoutReplay
    module_function
    def build(base:, resolved:, attempt:)
      raise Publication::Invalid, :invalid_knockout_configuration unless base.is_a?(Hash)
      expected = KnockoutRound.build(seeds: base['seeds'], players_per_match: base['players_per_match'], round_number: base['round'])
      unless expected.eql?(base) && Publication::Data.integer?(attempt, 1) && attempt <= 255
        raise Publication::Invalid, :invalid_knockout_configuration
      end
      Standings.calculate(units: base['seeds'], results: resolved)
      index = base['matches'].to_h { |match| [match['id'], match['participants']] }
      unless resolved.all? { |result| index[result['id']] == result['participants'] && result['winners'].size == 1 }
        raise Publication::Invalid, :invalid_phase_results
      end
      resolved = resolved.sort_by { |result| result['id'] }
      pending = base['matches'].reject { |match| resolved.any? { |result| result['id'] == match['id'] } }
      raise Publication::Invalid, :invalid_phase_results if pending.empty?
      replay = {'attempt' => attempt, 'base_plan' => base, 'resolved_results' => resolved}
      generation = Digest::SHA256.hexdigest(JSON.generate(['knockout-replay-v1', replay]))
      matches = pending.map.with_index { |match, index| {'id' => "#{generation}:#{index + 1}", 'participants' => match['participants']} }
      Publication::Data.freeze_tree(Publication::Data.copy(base.merge('generation' => generation, 'matches' => matches, 'replay' => replay),
        max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16))
    end

    def from_metadata(metadata)
      replay = metadata['replay']
      CoordinationRequest.fields!(replay, %w[attempt base_plan resolved_results])
      plan = build(base: replay['base_plan'], resolved: replay['resolved_results'], attempt: replay['attempt'])
      unless plan.slice('round', 'seeds', 'players_per_match', 'generation').eql?(metadata.slice('round', 'seeds', 'players_per_match', 'generation'))
        raise Publication::Invalid, :phase_changed
      end
      plan
    end
  end
end
