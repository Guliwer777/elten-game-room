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
      raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) || read_result_document(candidate,id,match)
      {'publication_ref'=>candidate['publication_ref'],'schedule_id'=>candidate['schedule_id'],
        'match_id'=>match['match_id'],'leg'=>match['leg'],'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding))}
    end

    def check_saved_match(saved,allow_linked:false,allow_prepared:false)
      marker=saved.fetch('tournament')
      candidate,id=source!
      raise OrdinaryMatchService::Blocked,:source_changed unless marker['publication_ref']==candidate['publication_ref'] && marker['schedule_id']==candidate['schedule_id']
      match=candidate['matches'].find{|row|row['match_id']==marker['match_id'] && row['leg']==marker['leg']}
      raise OrdinaryMatchService::Blocked,:missing_match unless match
      raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) || read_result_document(candidate,id,match)
      binding=read_match_binding(candidate,id,match,nil)
      raise OrdinaryMatchService::Blocked,:not_match_creator unless binding && binding['creator']==@owner
      same=binding && Digest::SHA256.hexdigest(JSON.generate(binding))==marker['binding_digest']
      linked=binding && binding.dig('continuation','save_checksum')==saved['checksum']
      same ||= allow_linked && linked
      if !same && allow_prepared && linked
        same=binding.dig('continuation','start_reserved')==true && !read_start_intent(candidate,id,match,binding)
      end
      raise OrdinaryMatchService::Blocked,:saved_match_changed unless same
      raise OrdinaryMatchService::Blocked,:wrong_game_players unless saved['players'].map{|name|name.downcase}==binding['players'].map{|person|person['account']} &&
        saved['game']==binding['game_id'] && saved_options(saved)==saved_options('game'=>binding['game_id'],'options'=>JSON.generate(binding['options']))
      @entry_guard&.call(candidate,match,binding)
      [candidate,id,match,binding]
    end

    def bind_resumed_match(saved,table,session)
      candidate,id,match,previous=check_saved_match(saved,allow_linked:true)
      snapshot=@games.snapshot_for(session,force_events:true)
      raise OrdinaryMatchService::Blocked,:wrong_resumed_session unless snapshot && snapshot.session['__archive_id'] &&
        snapshot.session['table_id']==table['__id'] && snapshot.session['game']==candidate['game_id'] &&
        @games.players_for(snapshot.session).map(&:downcase)==previous['players'].map{|person|person['account']}
      prefix=snapshot.events.first(saved['events'].size).map{|event|event.slice('actor','action','value')}
      original=saved['events'].map{|event|event.slice('actor','action','value')}
      raise OrdinaryMatchService::Blocked,:wrong_resumed_history unless prefix==original
      if previous.dig('continuation','save_checksum')==saved['checksum']
        raise OrdinaryMatchService::Blocked,:wrong_resumed_session unless previous['session_id']==session['__id'] &&
          previous['table']['__live_session_id']==table['__live_session_id'] && previous['table']['__id']==table['__id'] &&
          previous.dig('continuation','archive_id')==snapshot.session['__archive_id']
        @lock.synchronize{@bindings[table['__id']]=[previous,candidate,id,match]}
        start_worker
        return previous
      end
      publish_saved_binding(saved,table,candidate,id,match,previous,
        session_id:snapshot.session['__id'],archive_id:snapshot.session['__archive_id'])
    end

    # Bind the waiting room before sending ordinary invitations. Its planned
    # seats and observer rules are then verified exactly like a new match.
    # This reserves identifiers only; no game or private archive is uploaded.
    def prepare_saved_match(saved,table)
      candidate,id,match,previous=check_saved_match(saved,allow_linked:true)
      marker=candidate.slice('publication_ref','schedule_id').merge(match.slice('match_id','leg'))
      raise OrdinaryMatchService::Blocked,:wrong_match_binding unless table['tournament_match']==marker &&
        table['resume_save_id']==saved['id'] && table['owner'].to_s.downcase==@owner &&
        table['game']==candidate['game_id'] && saved_options('game'=>table['game'],'options'=>table['game_options'])==previous['options']
      if previous.dig('continuation','save_checksum')==saved['checksum']
        if previous['table']['__id']==table['__id'] && previous['table']['__live_session_id']==table['__live_session_id']
          raise OrdinaryMatchService::Blocked,:table_already_has_games unless @transport.game_sessions(table,force:true).empty?
          remember_binding(previous,candidate,id,match)
          return previous
        end
        # Closing a waiting room does not consume the account save. Reopening
        # it may replace only our explicitly reserved, never-started room.
        raise OrdinaryMatchService::Blocked,:closed_match_needs_recovery unless previous.dig('continuation','start_reserved')==true &&
          !read_start_intent(candidate,id,match,previous)
        available=@transport.discover_rooms(include_private:true).any?{|room|room['__live_session_id']==previous['table']['__live_session_id']}
        raise OrdinaryMatchService::Blocked,:wrong_resumed_session if available
      end
      raise OrdinaryMatchService::Blocked,:table_already_has_games unless @transport.game_sessions(table,force:true).empty?
      key=continuation_anchor(candidate,id,match,previous)
      retained=@journal.find(kind:'plan_document',intent_id:'ordinary-document:'+key['operation_key'])
      retained=StrictJson.parse(retained['values']['document_json'],max_nesting:12).fetch('binding') if retained
      publish_saved_binding(saved,table,candidate,id,match,previous,
        session_id:retained ? retained.fetch('session_id') : SecureRandom.random_number(2_000_000_000)+1,
        archive_id:retained ? retained.fetch('continuation').fetch('archive_id') : SecureRandom.uuid,reserve_start:true)
    end

    def start_saved_match(saved,table)
      binding=prepare_saved_match(saved,table)
      row=@lock.synchronize{@bindings.fetch(table['__id'])}
      retain_start_intent(row[1],row[2],row[3],binding)
      binding
    end

    private
    def publish_saved_binding(saved,table,candidate,id,match,previous,session_id:,archive_id:,reserve_start:false)
      original=saved['events'].map{|event|event.slice('actor','action','value')}
      binding=Data.copy(previous)
      binding['session_id']=session_id
      binding['table']=table.slice('__id','__live_session_id','name','game','owner','game_options','tournament_match')
      binding['continuation']={'save_checksum'=>saved['checksum'],'archive_id'=>archive_id,
        'event_count'=>original.size,'prefix_digest'=>Digest::SHA256.hexdigest(JSON.generate(original))}
      binding['continuation']['start_reserved']=true if reserve_start
      # Keep the live executor's binding byte-identical to the canonical
      # server document, including fields added when resuming a saved game.
      binding=Data.copy(binding)
      raise OrdinaryMatchService::Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match)
      document={'kind'=>'ordinary-match-continuation-v1','publication_ref'=>candidate['publication_ref'],
        'schedule_id'=>candidate['schedule_id'],'match_id'=>match['match_id'],'leg'=>match['leg'],
        'previous_digest'=>binding_digest(previous),'binding'=>binding}
      key=continuation_anchor(candidate,id,match,previous)
      publish_document(document,key) do |value|
        current,current_id=source!
        current==candidate && current_id==id && value==document &&
          !forfeit_document(candidate,id,match) && !read_result_document(candidate,id,match) &&
          (!@entry_guard || !!@entry_guard.call(candidate,match,previous))
      end
      @lock.synchronize{@bindings[table['__id']]=[Data.freeze_tree(binding),candidate,id,match]}
      start_worker
      binding
    end

    def saved_options(saved)
      value=@registry.build(saved['game']).normalize_options(StrictJson.parse(saved['options'],max_nesting:12))
      value.key?('team_players') ? value.merge('team_players'=>value['team_players'].map(&:downcase)) : value
    end
    def continuation_anchor(candidate,id,match,binding)
      anchor(candidate,id,match,'binding').merge('operation_key'=>Digest::SHA256.hexdigest(JSON.generate([
        'ordinary-continuation-v1',@journal.backend_identity,Digest::SHA256.hexdigest(JSON.generate(binding))])))
    end
    def read_match_binding(candidate,id,match,creator,initial:nil,stop_at:nil)
      binding=initial || initial_match_binding(candidate,id,match)
      return nil unless binding
      64.times do
        raise OrdinaryMatchService::Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match)
        return binding if stop_at && binding_digest(binding)==stop_at
        following=next_match_binding(candidate,id,match,binding)
        return binding unless following
        binding=following
      end
      raise OrdinaryMatchService::Blocked,:continuation_limit
    end

    def next_match_binding(candidate,id,match,binding,creator_rows:nil,continuation_rows:nil)
      if creator_rows.nil? && continuation_rows.nil?
        creator_key=entry_anchor(candidate,id,match,'creator',binding)['operation_key']
        continuation_key=continuation_anchor(candidate,id,match,binding)['operation_key']
        grouped=ServerDocumentRows.read_keys(@table,[creator_key,continuation_key],guard:method(:account!)).group_by{|row|row.fetch('operation_key')}
        creator_rows=grouped[creator_key] || []
        continuation_rows=grouped[continuation_key] || []
      end
      next_creator=elected_creator(candidate,id,match,binding,rows:creator_rows)
      author=next_creator || binding['creator']
      value=read_document(continuation_anchor(candidate,id,match,binding),author,rows:continuation_rows)
      return nil unless value
      replacement=value['kind']=='ordinary-match-replacement-v1'
      saved=value['kind']=='ordinary-match-continuation-v1'
      raise OrdinaryMatchService::Blocked,:invalid_continuation unless (replacement || saved) &&
        value['publication_ref']==candidate['publication_ref'] && value['schedule_id']==candidate['schedule_id'] &&
        value['match_id']==match['match_id'] && value['leg']==match['leg'] &&
        value['previous_digest']==binding_digest(binding) && value['binding'].is_a?(Hash) &&
        (replacement ? next_creator==value['binding']['creator'] && !value['binding'].key?('continuation') :
          author==binding['creator'] && value['binding'].dig('continuation','save_checksum').is_a?(String))
      value['binding']
    end
  end
end
