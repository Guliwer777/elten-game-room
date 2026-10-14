require_relative 'knockout_phase'

module GameRoomTournaments
  # One sports schedule for individual players and indivisible team units.
  # Native roles are assigned later by the existing family seat producer.
  module KnockoutSchedule
    module_function
    def direct_metadata(seeds:, generation:, publication_digest:, rematch: false,target:nil)
      raise Publication::Invalid, :invalid_participants unless seeds.size == 2
      plan = KnockoutRound.build(seeds: seeds, players_per_match: 2, round_number: 1)
      raise Publication::Invalid,:invalid_win_target if target && rematch
      plan=KnockoutWinSeries.build(base:plan,history:[],target:target,attempt:1) if target
      result = plan.slice('round', 'seeds', 'players_per_match', 'generation').merge(
        'origin' => 'direct_final', 'publication_digest' => publication_digest,
        'phase_digest' => KnockoutPhase.digest(rematch ? ['direct-final-v2', generation, publication_digest, seeds, true] : ['direct-final-v1', generation, publication_digest, seeds]))
      result['rematch'] = true if rematch
      if target
        result['series']=plan['series']
        result['phase_digest']=KnockoutPhase.digest(['direct-final-win-series-v1',generation,publication_digest,seeds,target])
      end
      result
    end

    def metadata(approval)
      phase = approval.fetch('preview')
      phase.fetch('plan').slice('round', 'seeds', 'players_per_match', 'generation', 'replay', 'rematch', 'qualification','series').merge(
        'phase_digest' => phase.fetch('digest'), 'parent_plan_digest' => phase.fetch('parent').fetch('plan_digest'))
    end

    def matches(metadata:, generation:, membership: nil)
      if metadata['origin'] == 'direct_final'
        fields = %w[round seeds players_per_match generation phase_digest origin publication_digest]
        fields += ['rematch'] if metadata.key?('rematch')
        fields += ['series'] if metadata.key?('series')
        CoordinationRequest.fields!(metadata, fields)
        ExecutionPlanContract.digest!(metadata['publication_digest'])
        expected = direct_metadata(seeds: metadata['seeds'], generation: generation, publication_digest: metadata['publication_digest'], rematch: metadata['rematch'] == true,target:metadata.dig('series','target'))
        raise Publication::Invalid, :phase_changed unless expected.eql?(metadata)
      else
        fields = %w[round seeds players_per_match generation phase_digest parent_plan_digest]
        fields += ['replay'] if metadata.key?('replay')
        fields += ['rematch'] if metadata.key?('rematch')
        fields += ['qualification'] if metadata.key?('qualification')
        fields += ['series'] if metadata.key?('series')
        raise Publication::Invalid, :invalid_rematch if metadata.key?('rematch') && (metadata['rematch'] != true || metadata.key?('replay') || metadata.key?('qualification'))
        CoordinationRequest.fields!(metadata, fields)
        ExecutionPlanContract.digest!(metadata['parent_plan_digest'])
      end
      ExecutionPlanContract.digest!(metadata['phase_digest'])
      plan = metadata.key?('series') ? KnockoutWinSeries.from_metadata(metadata) : metadata.key?('qualification') ? GroupTiebreak.from_metadata(metadata) : metadata.key?('replay') ? KnockoutReplay.from_metadata(metadata) :
        KnockoutRound.build(seeds: metadata['seeds'], players_per_match: metadata['players_per_match'], round_number: metadata['round'])
      raise Publication::Invalid, :phase_changed unless plan['generation'] == metadata['generation']
      units = membership && membership['units'].to_h { |unit| [unit['unit_id'], unit['accounts']] }
      if units && units.keys.sort != metadata['seeds'].sort
        raise Publication::Invalid, :invalid_membership
      end
      schedule = KnockoutPhase.digest(['knockout-execution-schedule-v1', generation, metadata])
      fixtures = plan['matches'].flat_map do |match|
        ids = match['participants']
        (metadata['rematch'] ? [1,2] : [1]).map do |leg|
          # Role assignment, shared with league returns, reverses the seats.
          # Keep the composition canonical for the first-leg lookup.
          order = ids
          identity = ['knockout-execution-match-v1', schedule, ids]
          identity << leg if metadata['rematch']
          value = {'number' => 0, 'players' => units ? order.flat_map { |id| units.fetch(id) } : order,
            'leg' => leg, 'match_id' => KnockoutPhase.digest(identity)}
          value['unit_ids'] = order if units
          value
        end
      end
      fixtures.each_with_index { |match, index| match['number'] = index + 1 }
      [schedule, fixtures]
    end

    def candidate(parent:, approval:)
      original = parent['preview']['source']['candidate']
      phase = approval['preview']
      seeds = phase['plan']['seeds']
      candidate = Publication::Data.copy(original, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16)
      candidate.delete('groups')
      candidate.delete('group_advancement')
      candidate.merge!('format' => 'knockout', 'rematch' => phase['plan']['rematch'] == true, 'knockout' => metadata(approval))
      membership = nil
      if parent['evidence']['version'] == 2
        qualification = original.dig('knockout','qualification','snapshot')
        root_membership = qualification && qualification['membership'] || original['membership']
        membership = root_membership.merge('units' => root_membership['units'].select { |unit| seeds.include?(unit['unit_id']) })
        accounts = membership['units'].flat_map { |unit| unit['accounts'] }.sort
        roster_source = qualification && qualification['roster'] || parent['evidence']['source']['roster']
        roster = roster_source.select { |person| accounts.include?(person['account']) }
        candidate['membership'] = membership
        generation = FixedTeamScheduleCandidate.digest(['tournament-fixed-team-roster-v1', original['backend_identity'],
          original['publication_ref'], original['publication_digest'], roster, membership])
        candidate['roster_digest'] = generation
      else
        accounts = seeds.sort
        generation = KnockoutPhase.digest(['knockout-roster-v1', original['roster_generation'], accounts])
      end
      candidate['roster'] = accounts
      candidate['roster_generation'] = generation
      candidate['schedule_id'], candidate['matches'] = matches(metadata: candidate['knockout'], generation: generation, membership: membership)
      KnockoutPhase.frozen_copy(candidate)
    end
  end
end
