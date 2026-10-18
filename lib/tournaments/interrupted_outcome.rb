# encoding: UTF-8
require_relative 'publication'

module GameRoomTournaments
  # Pure administrative settlement. Authorization and accepted-history reads
  # belong to the caller; this never fabricates a normally finished replay.
  module InterruptedOutcome
    Data = Publication::Data
    module_function

    def build(units:, loser:, started:, checkpoint:, continuation:, event_count:, eliminations: [])
      unless units.is_a?(Array) && units.size.between?(2,8) && units.uniq.size==units.size &&
          units.all? { |unit| unit.is_a?(String) && !unit.empty? } && units.include?(loser) &&
          [true,false].include?(started) && Data.integer?(event_count)
        raise Publication::Invalid, :invalid_interrupted_outcome
      end
      checkpoint = validate_checkpoint(checkpoint, units)
      groups = validate_eliminations(eliminations, units)
      active = units - groups.flatten
      raise Publication::Invalid, :invalid_interrupted_outcome unless active.include?(loser) && active.size >= 2
      if started && active.size > 2 && continuation == {'status'=>'continue'}
        decision = {'loser'=>loser, 'mode'=>'continue', 'basis'=>'continued', 'checkpoint'=>checkpoint}
        decision['eliminations'] = groups unless groups.empty?
        return Data.freeze_tree(Data.copy({'decision'=>decision}))
      end
      remaining = (active-[loser]).sort
      scores = checkpoint['status']=='scored' ? checkpoint.fetch('scores') : nil
      order = checkpoint['status']=='scored' ? checkpoint.fetch('order') : nil
      basis = if !started
        scores = order = nil
        'unstarted'
      elsif active.size==2
        'opponent'
      else
        unless continuation=={'status'=>'cannot_continue'}
          raise Publication::Invalid, :tournament_continuation_unsupported
        end
        case checkpoint['status']
        when 'scored' then 'scored_round'
        when 'none' then 'no_scored_round'
        else raise Publication::Invalid, :tournament_checkpoint_unsupported
        end
      end
      places = if basis=='scored_round'
        remaining.sort_by { |unit| order=='lower' ? scores.fetch(unit) : -scores.fetch(unit) }.
          chunk_while { |left,right| scores.fetch(left)==scores.fetch(right) }.map(&:sort)
      else
        [remaining]
      end
      places << [loser]
      places.concat(groups.reverse)
      summary = {'participants'=>units.sort,'winners'=>places.first,'draw'=>false,
        'scores'=>scores,'event_count'=>event_count,'places'=>places}
      summary['score_order']=order if order
      decision = {'loser'=>loser,'mode'=>'terminal','basis'=>basis,'checkpoint'=>checkpoint}
      decision['eliminations'] = groups unless groups.empty?
      Data.freeze_tree(Data.copy({'decision'=>decision,'summary'=>summary}))
    end

    def validate_eliminations(groups, units)
      unless groups.is_a?(Array) && groups.all? { |group| group.is_a?(Array) && !group.empty? &&
          group.all? { |unit| units.include?(unit) } } && groups.flatten.uniq == groups.flatten &&
          groups.flatten.size <= units.size - 2
        raise Publication::Invalid, :invalid_interrupted_outcome
      end
      groups.map { |group| group.sort }
    end

    def validate_checkpoint(checkpoint, units)
      unless checkpoint.is_a?(Hash) && %w[scored none unsupported].include?(checkpoint['status'])
        raise Publication::Invalid, :invalid_tournament_checkpoint
      end
      if checkpoint['status']=='scored'
        scores=checkpoint['scores']
        unless checkpoint.keys.sort==%w[event_id index kind order scores status] &&
            checkpoint['kind'].is_a?(String) && checkpoint['kind'].bytesize.between?(1,64) &&
            Data.integer?(checkpoint['index'],1) && Data.integer?(checkpoint['event_id'],1) &&
            %w[higher lower].include?(checkpoint['order']) && scores.is_a?(Hash) && scores.keys.all? { |unit| unit.is_a?(String) } && scores.keys.sort==units.sort &&
            scores.values.all? { |score| score.is_a?(Integer) || score.is_a?(Float) && score.finite? }
          raise Publication::Invalid, :invalid_tournament_checkpoint
        end
      elsif checkpoint.keys!=['status']
        raise Publication::Invalid, :invalid_tournament_checkpoint
      end
      Data.freeze_tree(Data.copy(checkpoint))
    end
  end
end
