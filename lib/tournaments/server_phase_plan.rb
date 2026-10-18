require_relative 'knockout_standings'
require_relative 'group_standings'
require_relative 'server_plan_document'

module GameRoomTournaments
  # Client-calculated sporting phase; no roster seal or global dispatch grant.
  module ServerPhasePlan
    Data=Publication::Data
    module_function
    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(value))
    end
    def build(candidate:,results:)
      team=candidate.key?('membership')
      key=team ? 'unit_ids' : 'players'
      units=team ? candidate['membership']['units'].map{|unit|unit['unit_id']} : candidate.fetch('roster')
      expected=candidate.fetch('matches').map{|match|[match['match_id'],match['leg']]}.sort
      actual=results.map{|receipt|[receipt['match_id'],receipt['leg']]}.sort
      raise Publication::Invalid,:invalid_phase_results unless actual.uniq==actual && (actual-expected).empty?
      raise Publication::Invalid,:phase_results_incomplete unless actual==expected && !expected.empty?
      normalized=results.map{|receipt|receipt.fetch('summary').slice('participants','winners','scores','score_order').merge('id'=>JSON.generate([receipt['match_id'],receipt['leg']]))}
      if candidate['format']=='groups_knockout'
        view=GroupStandings.calculate(candidate:candidate,units:units,results:normalized,unit_key:key,players_per_match:2)
        if view['group_state']=='ready_knockout'
          seeds=view.fetch('cross_seeding').fetch('seeds')
          plan=KnockoutRound.from_qualification(qualified:view['qualified'],seeds:seeds,players_per_match:2)
        else
          raise Publication::Invalid,:group_tie_requires_resolution unless GroupAdvancement.automatic?(candidate['group_advancement'])
          plan=GroupTiebreak.build(snapshot:GroupTiebreak.snapshot(summary:view,candidate:candidate),attempt:1)
        end
      elsif candidate['format']=='knockout'
        view=KnockoutStandings.calculate(candidate:candidate,units:units,results:normalized,unit_key:key)
        if candidate['knockout']['qualification']
          progress=view.fetch('qualification_progress')
          if progress['state']=='ready_knockout'
            projection=progress.fetch('projection')
            plan=KnockoutRound.from_qualification(qualified:projection['qualified'],seeds:projection['cross_seeding']['seeds'],players_per_match:2)
          else
            plan=GroupTiebreak.build(snapshot:progress['snapshot'],attempt:candidate['knockout']['qualification']['attempt']+1)
          end
        else
        case view['knockout_state']
        when 'completed'
          raise Publication::Invalid,:tournament_completed
        when 'ready_next_round'
          plan=KnockoutRound.build(seeds:view['qualified'],players_per_match:2,round_number:candidate['knockout']['round']+1)
        when 'tie_requires_resolution'
          plan=KnockoutReplay.build(base:view['knockout_progress']['plan'],resolved:Data.copy(view['knockout_resolved_results']),attempt:candidate['knockout'].dig('replay','attempt').to_i+1)
        when 'awaiting_series'
          series=candidate['knockout']['series']
          plan=KnockoutWinSeries.build(base:series['base_plan'],history:Data.copy(view['series_history'],max_bytes:262144,max_nodes:16384,max_depth:12),target:series['target'],attempt:series['attempt']+1)
        else
          raise Publication::Invalid,:phase_results_incomplete
        end
        end
      else
        raise Publication::Invalid,:unsupported_format
      end
      unless plan.key?('replay') || plan.key?('series') || plan.key?('qualification')
        setting=plan['seeds'].size==2 ? 'final_rematch' : 'knockout_rematch'
        target=candidate[setting.sub('rematch','wins_to')]
        plan=target ? KnockoutWinSeries.build(base:plan,history:[],target:target,attempt:1) : candidate[setting]==true ? plan.merge('rematch'=>true) : plan
      end
      parent=digest(candidate)
      evidence=digest(results.sort_by{|receipt|[receipt['match_id'],receipt['leg']]})
      metadata=plan.slice('round','seeds','players_per_match','generation','replay','rematch','series','qualification').merge(
        'phase_digest'=>digest(['server-sporting-phase-v1',parent,evidence,plan]),'parent_plan_digest'=>parent)
      next_candidate=Data.copy(candidate,max_bytes:262144,max_nodes:16384,max_depth:16)
      next_candidate.delete('groups')
      next_candidate.delete('group_advancement')
      seeds=plan['seeds']
      membership=nil
      if team
        original=candidate.dig('knockout','qualification','snapshot','membership') || candidate['membership']
        membership=original.merge('units'=>original['units'].select{|unit|seeds.include?(unit['unit_id'])})
        next_candidate['membership']=membership
        accounts=membership['units'].flat_map{|unit|unit['accounts']}.sort
      else
        accounts=seeds.sort
      end
      generation=digest(['server-phase-roster-v1',candidate['roster_generation'],accounts,membership])
      next_candidate.merge!('format'=>'knockout','knockout'=>metadata,'rematch'=>metadata['rematch']==true,'roster'=>accounts,'roster_generation'=>generation)
      next_candidate['roster_digest']=generation if team
      next_candidate['schedule_id'],next_candidate['matches']=KnockoutSchedule.matches(metadata:metadata,generation:generation,membership:membership)
      document={'kind'=>'server-sporting-phase-v1','publication_ref'=>candidate.fetch('publication_ref'),
        'parent_schedule_id'=>candidate['schedule_id'],'parent_digest'=>parent,'result_digest'=>evidence,'candidate'=>next_candidate}
      Data.freeze_tree(ServerPlanDocument.copy_document(document))
    end
  end
end
