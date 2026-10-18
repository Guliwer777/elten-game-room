# encoding: UTF-8
require_relative 'interrupted_outcome'
module GameRoomTournaments
  module OrdinaryMatchForfeit
    Data = Publication::Data
    # Read-only proposal. The returned immutable document is the exact intent
    # confirmed by the organizer; committing a changed projection needs consent
    # again, not a silent recomputation of the winner or places.
    def forfeit_preview(match_id:, leg:, loser:, expected_schedule_id:)
      candidate,id=source!
      match=forfeit_match!(candidate,match_id,leg,expected_schedule_id)
      raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) ||
        read_result_document(candidate,id,match)
      build_forfeit_preview(candidate,id,match,loser)
    end

    def confirm_forfeit(preview:)
      candidate,id=source!
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt unless preview.is_a?(Hash)
      match=forfeit_match!(candidate,preview['match_id'],preview['leg'],preview['schedule_id'])
      document=Data.freeze_tree(ServerPlanDocument.copy_document(preview))
      return confirm_continuing_forfeit(document,candidate,id,match) if document['kind']=='ordinary-match-elimination-v1'
      validate_forfeit_v2!(document,candidate,match)
      verify_forfeit_v2_intent!(document,candidate,id,match)
      key=anchor(candidate,id,match,'forfeit')
      digest=Digest::SHA256.hexdigest(JSON.generate(document))
      forfeit_archive(document,candidate,id,match).publish(
        intent_id:'ordinary-forfeit:'+key['operation_key']+':'+digest,document:document,anchor:key)
      view=result_view
      @result_changed.call(candidate.fetch('publication_ref'))
      view
    end

    # Historical v1 documents remain readable. Neither old UI callbacks nor a
    # retained operation may publish a new winner-based decision.
    def award_forfeit(**_legacy_arguments)
      raise OrdinaryMatchService::Blocked,:legacy_forfeit_write_disabled
    end

    private
    def forfeit_match!(candidate,match_id,leg,schedule_id)
      raise OrdinaryMatchService::Blocked,:not_organizer unless candidate.fetch('publication_ref').fetch('author').downcase==@owner
      raise OrdinaryMatchService::Blocked,:source_changed unless candidate['schedule_id']==schedule_id
      match=candidate.fetch('matches').find { |row| row['match_id']==match_id && row['leg']==leg }
      raise OrdinaryMatchService::Blocked,:missing_match unless match && supported_match?(candidate,match)
      match
    end

    def build_forfeit_preview(candidate,id,match,loser)
      units=(match['unit_ids'] || match['players']).sort
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_loser unless units.include?(loser)
      binding=read_match_binding(candidate,id,match,nil)
      raise OrdinaryMatchService::Blocked,:wrong_match_binding if binding && !valid_binding?(binding,candidate,match)
      boundary=nil
      checkpoint={'status'=>'unsupported'}
      continuation={'status'=>'unsupported'}
      eliminations=[]
      if binding
        raise OrdinaryMatchService::Blocked,:game_state_unavailable unless @transport
        sessions=forfeit_native_sessions(candidate,id,match,binding)
        unless sessions.empty?
          raise OrdinaryMatchService::Blocked,:wrong_bound_session unless sessions.first['__id']==binding['session_id']
          boundary,game,replay,session=session_for_forfeit(binding)
          checkpoint=game.tournament_scored_checkpoint(replay,options:binding['options'])
          if checkpoint.is_a?(Hash) && checkpoint['status']=='scored'
            checkpoint=map_forfeit_checkpoint(checkpoint,game,replay,binding,candidate,match)
          end
          mapping=GameResult.roster_mapping(game:game,replay:replay,options:binding['options'],players:binding['players'])
          continuation=game.tournament_forfeit_continuation(replay,losing_unit:mapping.key(loser),options:binding['options'])
          eliminations=GameResult.eliminations(replay,players:binding['players'])
        end
      end
      outcome=InterruptedOutcome.build(units:units,loser:loser,started:!boundary.nil?,
        checkpoint:checkpoint,continuation:continuation,event_count:boundary ? boundary['event_count'] : 0,
        eliminations:eliminations)
      document={'kind'=>'ordinary-match-forfeit-v2','schedule_id'=>candidate['schedule_id'],
        'match_id'=>match['match_id'],'leg'=>match['leg'],'publication_ref'=>candidate.fetch('publication_ref'),
        'organizer'=>@owner,**outcome}
      document['cancelled_game']=boundary if boundary
      if outcome.dig('decision','mode')=='continue'
        document['kind']='ordinary-match-elimination-v1'
        document['continued_game']=document.delete('cancelled_game')
        room=@transport.room_snapshot(binding['table'],read_only:true)
        raise OrdinaryMatchService::Blocked,:game_state_unavailable unless room && room[:members]
        active=game.tournament_active_players(replay,options:binding['options'])
        absent=active.reject { |player| GameRoomParticipants.includes?(room[:members],player) }
        document['native_boundary']=GameRoomTournamentPresence.data(session:session,
          fixture:binding['table'].fetch('tournament_match'),binding_digest:boundary['binding_digest'],
          absent:absent,elapsed_ms:0,loser:mapping.key(loser),mode:'continue',origin:'organizer')
      end
      Data.freeze_tree(Data.copy(document))
    rescue Publication::Invalid=>error
      raise unless [:tournament_continuation_unsupported,:tournament_checkpoint_unsupported].include?(error.code)
      raise OrdinaryMatchService::Blocked,error.code
    end

    def confirm_continuing_forfeit(document,candidate,id,match)
      binding=read_match_binding(candidate,id,match,nil)
      validate_continuing_forfeit!(document,candidate,match,binding)
      session=@games.session_by_id(binding['session_id'],table:binding['table'])
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless session
      guard=lambda do |_current|
        account!
        current,current_id=source!
        raise OrdinaryMatchService::Blocked,:source_changed unless current==candidate && current_id==id
        raise OrdinaryMatchService::Blocked,:result_already_recorded if forfeit_document(candidate,id,match) || read_result_document(candidate,id,match)
        fresh=build_forfeit_preview(candidate,id,match,document['decision']['loser'])
        raise OrdinaryMatchService::Blocked,:forfeit_preview_changed unless fresh==document
        true
      end
      record=@transport.append_tournament_presence(session,data:document['native_boundary'],
        message_id:Digest::SHA256.hexdigest(JSON.generate(document)),write_guard:guard)
      raise OrdinaryMatchService::Blocked,:forfeit_preview_changed unless record
      # A native receipt confirms storage, not acceptance of its CAS. Inspect
      # this exact decision in history; later accepted decisions do not undo it.
      snapshot=@games.snapshot_for(session,force_events:true)
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless snapshot
      replay=@registry.build(binding['game_id']).replay(snapshot.session,snapshot.events,@games)
      account!
      unless replay.accepted_events.any? { |event| event['__tournament_elimination']==true && event['move_id']==record.message_id }
        raise OrdinaryMatchService::Blocked,:forfeit_preview_changed
      end
      @result_changed.call(candidate.fetch('publication_ref'))
      result_view
    end

    def validate_continuing_forfeit!(document,candidate,match,binding)
      keys=%w[continued_game decision kind leg match_id native_boundary organizer publication_ref schedule_id]
      decision=document['decision']
      unless document.keys.sort==keys && document['schedule_id']==candidate['schedule_id'] &&
          document['match_id']==match['match_id'] && document['leg']==match['leg'] &&
          document['publication_ref']==candidate['publication_ref'] && document['organizer']==@owner &&
          binding && valid_binding?(binding,candidate,match) && !match.key?('unit_ids') && decision.is_a?(Hash)
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
      end
      boundary=document['continued_game']
      validate_cancellation_boundary!(boundary)
      expected=InterruptedOutcome.build(units:match['players'].sort,loser:decision['loser'],started:true,
        checkpoint:decision['checkpoint'],continuation:{'status'=>'continue'},event_count:boundary['event_count'],
        eliminations:decision.fetch('eliminations',[]))
      value=document['native_boundary']
      unless expected=={'decision'=>decision} && boundary['session_id']==binding['session_id'] &&
          boundary['binding_digest']==Digest::SHA256.hexdigest(JSON.generate(binding)) && value.is_a?(Hash) &&
          value['session_id']==binding['session_id'] && value['tournament_presence'].is_a?(Hash) &&
          value['tournament_presence'].slice('binding_digest','fixture','origin','mode','elapsed_ms')=={
            'binding_digest'=>boundary['binding_digest'],'fixture'=>binding['table']['tournament_match'],
            'origin'=>'organizer','mode'=>'continue','elapsed_ms'=>0} &&
          value['tournament_presence']['loser'].is_a?(String) && value['tournament_presence']['loser'].downcase==decision['loser']
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
      end
    rescue Publication::Invalid
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
    end

    def map_forfeit_checkpoint(checkpoint,game,replay,binding,candidate,match)
      assignment=game.prepared_team_assignment(game.normalize_options(binding['options']),players:replay.players)
      units=assignment ? assignment.team_ids.to_h { |unit| [unit,assignment.members_for(unit)] } :
        replay.players.to_h { |player| [player,[player]] }
      mapping=GameResult.unit_mapping(units:units,players:prepared_match(candidate,match)['players'])
      scores=checkpoint['scores']
      unless scores.is_a?(Hash) && scores.keys.sort==mapping.keys.sort
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_checkpoint
      end
      checkpoint.merge('scores'=>scores.to_h { |unit,score| [mapping.fetch(unit),score] })
    rescue Publication::Invalid
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_checkpoint
    end

    def verify_forfeit_v2_intent!(document,candidate,id,match)
      current,current_id=source!
      raise OrdinaryMatchService::Blocked,:source_changed unless current==candidate && current_id==id
      forfeit_match!(current,match['match_id'],match['leg'],candidate['schedule_id'])
      validate_forfeit_v2!(document,candidate,match)
      accepted=forfeit_document(candidate,id,match)
      if accepted
        raise OrdinaryMatchService::Blocked,:conflicting_document unless accepted==document
        if document['cancelled_game']
          binding=read_match_binding(candidate,id,match,nil)
          raise OrdinaryMatchService::Blocked,:wrong_match_binding unless cancellation_valid_binding?(document,binding,candidate,match)
        end
        return true # Already accepted cutoff: later gameplay cannot undo it.
      end
      raise OrdinaryMatchService::Blocked,:result_already_recorded if read_result_document(candidate,id,match)
      fresh=build_forfeit_preview(candidate,id,match,document.fetch('decision').fetch('loser'))
      raise OrdinaryMatchService::Blocked,:forfeit_preview_changed unless fresh==document
      true
    end

    def validate_forfeit_v2!(value,candidate,match)
      units=(match['unit_ids'] || match['players']).sort
      keys=%w[decision kind leg match_id organizer publication_ref schedule_id summary]
      keys << 'cancelled_game' if value.key?('cancelled_game')
      decision=value['decision']
      unless value.keys.sort==keys.sort && value['kind']=='ordinary-match-forfeit-v2' &&
          value['schedule_id']==candidate['schedule_id'] && value['match_id']==match['match_id'] && value['leg']==match['leg'] &&
          value['publication_ref']==candidate['publication_ref'] && value['organizer']==candidate.fetch('publication_ref').fetch('author').downcase &&
          decision.is_a?(Hash) && decision.keys.sort==(%w[basis checkpoint loser mode]+(decision.key?('eliminations') ? ['eliminations'] : [])).sort && decision['mode']=='terminal'
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
      end
      boundary=value['cancelled_game']
      validate_cancellation_boundary!(boundary) if boundary
      expected=InterruptedOutcome.build(units:units,loser:decision['loser'],started:!boundary.nil?,
        checkpoint:decision['checkpoint'],continuation:{'status'=>'cannot_continue'},event_count:boundary ? boundary['event_count'] : 0,
        eliminations:decision.fetch('eliminations',[]))
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt unless value['decision']==expected['decision'] && value['summary']==expected['summary']
      true
    rescue Publication::Invalid
      raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
    end

    def validate_cancellation_boundary!(boundary)
      unless boundary.is_a?(Hash) && boundary.keys.sort==%w[binding_digest event_count history_digest session_id] &&
          %w[binding_digest history_digest].all? { |key| boundary[key].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(boundary[key]) } &&
          Publication::Data.integer?(boundary['session_id'],1) && Publication::Data.integer?(boundary['event_count'])
        raise OrdinaryMatchService::Blocked,:invalid_forfeit_receipt
      end
    end

    def cancellation_boundary(binding)
      session_for_forfeit(binding).first
    end

    def forfeit_native_sessions(candidate,id,match,binding,start_rows:nil)
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless @transport
      sessions=@transport.game_sessions(binding['table'],force:true)
      if sessions.empty? && (binding['entry_version']!=OrdinaryMatchEntry::ENTRY_VERSION ||
          binding.key?('continuation') || read_start_intent(candidate,id,match,binding,rows:start_rows))
        # game_sessions is membership-local. A missing/closed native projection
        # is not evidence that an accepted or uncertain start never happened.
        raise OrdinaryMatchService::Blocked,:game_state_unavailable
      end
      sessions
    end

    def session_for_forfeit(binding)
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
      raise OrdinaryMatchService::Blocked,:game_state_unavailable unless GameResult.valid_replay_history?(replay,snapshot.events) &&
        replay.players.map { |name| Data.account(name).downcase }.sort==binding['players'].map { |person| person['account'] }.sort
      raise OrdinaryMatchService::Blocked,:result_already_recorded if replay.finished? || session['__aborted']
      boundary={'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding)),'session_id'=>binding['session_id'],
        'event_count'=>snapshot.events.size,'history_digest'=>Digest::SHA256.hexdigest(JSON.generate(snapshot.events))}
      [boundary,game,replay,session]
    end
    def cancellation_valid_binding?(value,binding,candidate,match)
      binding && valid_binding?(binding,candidate,match) &&
        value['cancelled_game']['binding_digest']==Digest::SHA256.hexdigest(JSON.generate(binding)) &&
        value['cancelled_game']['session_id']==binding['session_id']
    end
    def forfeit_document(candidate,id,match,rows:nil,result_rows:nil)
      attempts=forfeit_receipts(candidate,id,match,rows:rows)
      return nil if attempts.empty?
      ordinary=ordinary_result_receipt(candidate,id,match,rows:result_rows,allow_incomplete:true)
      entry=ordered_match_receipts(attempts,ordinary).first
      return nil if entry['document']['kind']=='ordinary-match-result-v1'
      yield entry if entry && block_given?
      entry && entry['document']
    end

    def ordered_match_receipts(forfeits,ordinary)
      # Both document kinds live in the same server table. Their completion
      # row IDs share one monotonic order, even when an older batch arrives late.
      (forfeits+(ordinary ? [ordinary] : [])).sort_by { |entry| entry['completed_row_id'] }
    end

    def ordinary_result_receipt(candidate,id,match,rows:nil,allow_incomplete:false)
      entry=nil
      document=read_result_document(candidate,id,match,rows:rows,allow_incomplete:allow_incomplete) do |time,evidence|
        entry=evidence.merge('time'=>time)
      end
      entry && entry.merge('document'=>document)
    end

    def forfeit_receipts(candidate,id,match,rows:nil)
      author=candidate.fetch('publication_ref').fetch('author').downcase
      key=anchor(candidate,id,match,'forfeit')
      rows ||= ServerDocumentRows.read(@table,where:{'operation_key'=>key['operation_key']},guard:method(:account!))
      account!
      ServerDocumentRows.owned(rows,author).group_by { |row| row['document_digest'] }.filter_map do |_digest,attempt|
        parts=ServerPlanDocument.canonical_rows(attempt,anchor:key,author:author)
        validate_forfeit_parts!(parts)
        # Only valid incomplete attempts are absent results. Broken payloads,
        # mixed parts, hashes and authenticated invalid receipts still fail.
        next unless parts.first['part_index']==0 && parts.size==parts.first['part_count']+1
        value=ServerPlanDocument.decode(parts,anchor:key,author:author)
        validate_forfeit!(value,candidate,match)
        {'document'=>value,'digest'=>parts.first['document_digest'],
          'completed_row_id'=>parts.map { |part| part['__id'] }.max,'time'=>document_time(parts)}
      end.sort_by { |entry| entry['completed_row_id'] }
    end

    def validate_forfeit_parts!(parts)
      first=parts.first
      parts.each do |part|
        raise Publication::Invalid,:invalid_plan_part unless part['part_count']==first['part_count'] &&
          part['document_digest']==first['document_digest']
        if part['part_index']==0
          raise Publication::Invalid,:invalid_plan_part unless part['payload']==''
          next
        end
        payload=part['payload']
        raise Publication::Invalid,:invalid_plan_encoding unless payload.is_a?(String) && payload.bytesize.between?(1,2048)
        begin
          bytes=Base64.strict_decode64(payload)
        rescue ArgumentError
          raise Publication::Invalid,:invalid_plan_encoding
        end
        raise Publication::Invalid,:invalid_plan_encoding unless bytes.bytesize.between?(1,ServerPlanDocument::PART_BYTES) &&
          (part['part_index']==part['part_count'] || bytes.bytesize==ServerPlanDocument::PART_BYTES)
      end
    end

    def forfeit_archive(document,candidate,id,match)
      expected=anchor(candidate,id,match,'forfeit')
      digest=Digest::SHA256.hexdigest(JSON.generate(ServerPlanDocument.copy_document(document)))
      ServerPlanArchive.new(table:@table,journal:@journal,user:-> {account!; @user.call},document_digest:digest,
        verify:->(value,retained) do
          retained==expected && value==document && verify_forfeit_v2_intent!(value,candidate,id,match)
        end)
    end
    def validate_forfeit!(value,candidate,match)
      return validate_forfeit_v2!(value,candidate,match) if value['kind']=='ordinary-match-forfeit-v2'
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
