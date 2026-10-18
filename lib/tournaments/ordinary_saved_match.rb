# encoding: UTF-8
module GameRoomTournaments
  module OrdinarySavedMatch
    Data=Publication::Data
    def saved_match_reference(table,session)
      row=@lock.synchronize{@bindings[table['__id']]}
      return nil unless row && row[0]['session_id']==session['__id']
      raise OrdinaryMatchService::Blocked,:tournament_saved_game_disabled
    end

    # Keep callable denials for old UI callbacks and retained operations. The
    # authenticated historical binding chain below remains readable, but a
    # private archive is no longer a source for a playable tournament match.
    def check_saved_match(saved,allow_linked:false,allow_prepared:false)
      raise OrdinaryMatchService::Blocked,:tournament_saved_game_disabled
    end

    def bind_resumed_match(saved,table,session)
      raise OrdinaryMatchService::Blocked,:tournament_saved_game_disabled
    end

    def prepare_saved_match(saved,table)
      raise OrdinaryMatchService::Blocked,:tournament_saved_game_disabled
    end

    def start_saved_match(saved,table)
      raise OrdinaryMatchService::Blocked,:tournament_saved_game_disabled
    end

    private
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
