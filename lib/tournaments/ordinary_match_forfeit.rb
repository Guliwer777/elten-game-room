# encoding: UTF-8
module GameRoomTournaments
  module OrdinaryMatchForfeit
    def award_forfeit(match_id:, leg:, winner:, expected_schedule_id:, cancel_started:false)
      candidate,id=source!
      raise OrdinaryMatchService::Blocked,:not_organizer unless candidate.fetch('publication_ref').fetch('author').downcase==@owner
      raise OrdinaryMatchService::Blocked,:source_changed unless candidate['schedule_id']==expected_schedule_id
      match=candidate.fetch('matches').find{|row|row['match_id']==match_id && row['leg']==leg}
      raise OrdinaryMatchService::Blocked,:missing_match unless match && supported_match?(candidate,match)
      units=(match['unit_ids'] || match['players']).sort
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_winner unless units.include?(winner)
      creator=prepared_match(candidate,match)['players'].first['account']
      document={'kind'=>'ordinary-match-forfeit-v1','schedule_id'=>candidate['schedule_id'],
        'match_id'=>match_id,'leg'=>leg,'publication_ref'=>candidate.fetch('publication_ref'),
        'summary'=>{'participants'=>units,'winners'=>[winner],'draw'=>false,'scores'=>nil,'event_count'=>0}}
      if cancel_started
        binding=read_match_binding(candidate,id,match,creator)
        raise OrdinaryMatchService::Blocked,:missing_match_binding unless binding && valid_binding?(binding,candidate,match)
        document['kind']='ordinary-match-cancel-forfeit-v1'
        document['cancelled_game']=cancellation_boundary(binding)
      end
      publish_document(document,anchor(candidate,id,match,'forfeit')) do |value|
        current,current_id=source!
        raise OrdinaryMatchService::Blocked,:source_changed unless current==candidate && current_id==id && value==document
        raise OrdinaryMatchService::Blocked,:result_already_recorded if read_document(anchor(candidate,id,match,'result'),creator)
        binding=read_match_binding(candidate,id,match,creator)
        if cancel_started
          raise OrdinaryMatchService::Blocked,:wrong_match_binding unless binding && valid_binding?(binding,candidate,match)
          raise OrdinaryMatchService::Blocked,:game_changed unless cancellation_boundary(binding)==document['cancelled_game']
        elsif binding
          raise OrdinaryMatchService::Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match)
          # No server compare-and-set exists here. Never decide over a started
          # native game, even when its result receipt has not arrived yet.
          raise OrdinaryMatchService::Blocked,:match_game_already_started unless @transport && @transport.game_sessions(binding['table'],force:true).empty?
        end
        true
      end
      result_view
    end

    private
    def cancellation_boundary(binding)
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless @games
      session=@games.session_by_id(binding['session_id'],table:binding['table'])
      snapshot=session && @games.snapshot_for(session,force_events:true)
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless snapshot
      session=snapshot.session
      raise OrdinaryMatchService::Blocked,:wrong_bound_session unless session['__id']==binding['session_id'] &&
        session['table_id']==binding['table']['__id'] && session['game']==binding['game_id'] &&
        OrdinaryMatchResults.valid_continuation?(binding,session,snapshot.events)
      game=@registry.build(binding['game_id'])
      replay=game.replay(session,snapshot.events,@games)
      raise OrdinaryMatchService::Blocked,:result_already_recorded if replay.finished?
      {'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding)),'session_id'=>binding['session_id'],
        'event_count'=>snapshot.events.size,'history_digest'=>Digest::SHA256.hexdigest(JSON.generate(snapshot.events))}
    end
    def cancellation_valid_binding?(value,binding,candidate,match)
      binding && valid_binding?(binding,candidate,match) &&
        value['cancelled_game']['binding_digest']==Digest::SHA256.hexdigest(JSON.generate(binding)) &&
        value['cancelled_game']['session_id']==binding['session_id']
    end
    def forfeit_document(candidate,id,match)
      author=candidate.fetch('publication_ref').fetch('author').downcase
      value=read_document(anchor(candidate,id,match,'forfeit'),author)
      validate_forfeit!(value,candidate,match) if value
      value
    end
    def validate_forfeit!(value,candidate,match)
      units=(match['unit_ids'] || match['players']).sort
      summary=value['summary']
      cancellation=value['kind']=='ordinary-match-cancel-forfeit-v1'
      keys=%w[kind leg match_id publication_ref schedule_id summary]
      keys << 'cancelled_game' if cancellation
      boundary=value['cancelled_game']
      if cancellation
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt unless boundary.is_a?(Hash) &&
          boundary.keys.sort==%w[binding_digest event_count history_digest session_id] &&
          %w[binding_digest history_digest].all?{|key|boundary[key].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(boundary[key])} &&
          Publication::Data.integer?(boundary['session_id'],1) && Publication::Data.integer?(boundary['event_count'])
      end
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt unless value.keys.sort==keys.sort &&
        (cancellation || value['kind']=='ordinary-match-forfeit-v1') && value['schedule_id']==candidate['schedule_id'] &&
        value['match_id']==match['match_id'] && value['leg']==match['leg'] && value['publication_ref']==candidate['publication_ref'] &&
        summary.is_a?(Hash) && summary.keys.sort==%w[draw event_count participants scores winners] &&
        summary['participants']==units && summary['winners'].is_a?(Array) && summary['winners'].size==1 &&
        units.include?(summary['winners'].first) && summary['draw']==false && summary['scores'].nil? && summary['event_count']==0
      true
    end
  end
end
