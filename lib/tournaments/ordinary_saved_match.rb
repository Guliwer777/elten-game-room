# encoding: UTF-8
module GameRoomTournaments
  module OrdinarySavedMatch
    Data=Publication::Data
    def saved_match_reference(table,session)
      row=@lock.synchronize{@bindings[table['__id']]}
      return nil unless row && row[0]['session_id']==session['__id']
      binding,candidate,id,match=row
      current,current_id=source!
      raise OrdinaryMatchService::Blocked,:source_changed unless current==candidate && current_id==id
      raise OrdinaryMatchService::Blocked,:not_match_creator unless binding['creator']==@owner
      raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) || read_document(anchor(candidate,id,match,'result'),@owner)
      {'publication_ref'=>candidate['publication_ref'],'schedule_id'=>candidate['schedule_id'],
        'match_id'=>match['match_id'],'leg'=>match['leg'],'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding))}
    end

    def check_saved_match(saved,allow_linked:false)
      marker=saved.fetch('tournament')
      candidate,id=source!
      raise OrdinaryMatchService::Blocked,:source_changed unless marker['publication_ref']==candidate['publication_ref'] && marker['schedule_id']==candidate['schedule_id']
      match=candidate['matches'].find{|row|row['match_id']==marker['match_id'] && row['leg']==marker['leg']}
      raise OrdinaryMatchService::Blocked,:missing_match unless match
      creator=prepared_match(candidate,match)['players'].first['account']
      raise OrdinaryMatchService::Blocked,:not_match_creator unless creator==@owner
      raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) || read_document(anchor(candidate,id,match,'result'),creator)
      binding=read_match_binding(candidate,id,match,creator)
      same=binding && Digest::SHA256.hexdigest(JSON.generate(binding))==marker['binding_digest']
      same ||= allow_linked && binding && binding.dig('continuation','save_checksum')==saved['checksum']
      raise OrdinaryMatchService::Blocked,:saved_match_changed unless same
      raise OrdinaryMatchService::Blocked,:wrong_game_players unless saved['players'].map{|name|name.downcase}==binding['players'].map{|person|person['account']} &&
        saved['game']==binding['game_id'] && saved_options(saved)==saved_options('game'=>binding['game_id'],'options'=>JSON.generate(binding['options']))
      [candidate,id,match,binding]
    end

    def bind_resumed_match(saved,table,session)
      candidate,id,match,previous=check_saved_match(saved,allow_linked:true)
      if previous.dig('continuation','save_checksum')==saved['checksum']
        raise OrdinaryMatchService::Blocked,:wrong_resumed_session unless previous['session_id']==session['__id'] && previous['table']['__live_session_id']==table['__live_session_id']
        @lock.synchronize{@bindings[table['__id']]=[previous,candidate,id,match]}
        start_worker
        return previous
      end
      snapshot=@games.snapshot_for(session,force_events:true)
      raise OrdinaryMatchService::Blocked,:wrong_resumed_session unless snapshot && snapshot.session['__archive_id'] &&
        snapshot.session['table_id']==table['__id'] && snapshot.session['game']==candidate['game_id'] &&
        @games.players_for(snapshot.session).map(&:downcase)==previous['players'].map{|person|person['account']}
      prefix=snapshot.events.first(saved['events'].size).map{|event|event.slice('actor','action','value')}
      original=saved['events'].map{|event|event.slice('actor','action','value')}
      raise OrdinaryMatchService::Blocked,:wrong_resumed_history unless prefix==original
      binding=Data.copy(previous)
      binding['session_id']=snapshot.session['__id']
      binding['table']=table.slice('__id','__live_session_id','name','game','owner','game_options')
      binding['continuation']={'save_checksum'=>saved['checksum'],'archive_id'=>snapshot.session['__archive_id'],
        'event_count'=>original.size,'prefix_digest'=>Digest::SHA256.hexdigest(JSON.generate(original))}
      raise OrdinaryMatchService::Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match)
      document={'kind'=>'ordinary-match-continuation-v1','publication_ref'=>candidate['publication_ref'],
        'schedule_id'=>candidate['schedule_id'],'match_id'=>match['match_id'],'leg'=>match['leg'],
        'previous_digest'=>saved['tournament']['binding_digest'],'binding'=>binding}
      key=continuation_anchor(candidate,id,match,previous)
      publish_document(document,key) do |value|
        current,current_id=source!
        current==candidate && current_id==id && value==document &&
          !forfeit_document(candidate,id,match) && !read_document(anchor(candidate,id,match,'result'),@owner)
      end
      @lock.synchronize{@bindings[table['__id']]=[Data.freeze_tree(binding),candidate,id,match]}
      start_worker
      binding
    end

    private
    def saved_options(saved)
      value=@registry.build(saved['game']).normalize_options(StrictJson.parse(saved['options'],max_nesting:12))
      value.key?('team_players') ? value.merge('team_players'=>value['team_players'].map(&:downcase)) : value
    end
    def continuation_anchor(candidate,id,match,binding)
      anchor(candidate,id,match,'binding').merge('operation_key'=>Digest::SHA256.hexdigest(JSON.generate([
        'ordinary-continuation-v1',@journal.backend_identity,Digest::SHA256.hexdigest(JSON.generate(binding))])))
    end
    def read_match_binding(candidate,id,match,creator,initial:nil)
      binding=initial || read_document(anchor(candidate,id,match,'binding'),creator)
      return nil unless binding
      16.times do
        raise OrdinaryMatchService::Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match)
        value=read_document(continuation_anchor(candidate,id,match,binding),creator)
        return binding unless value
        raise OrdinaryMatchService::Blocked,:invalid_continuation unless value['kind']=='ordinary-match-continuation-v1' &&
          value['publication_ref']==candidate['publication_ref'] && value['schedule_id']==candidate['schedule_id'] &&
          value['match_id']==match['match_id'] && value['leg']==match['leg'] &&
          value['previous_digest']==Digest::SHA256.hexdigest(JSON.generate(binding)) && value['binding'].is_a?(Hash) &&
          value['binding'].key?('continuation') && value['binding']['continuation']['save_checksum'].is_a?(String)
        binding=value['binding']
      end
      raise OrdinaryMatchService::Blocked,:continuation_limit
    end
  end
end
