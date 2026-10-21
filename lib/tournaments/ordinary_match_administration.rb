# encoding: UTF-8
require_relative 'administrative_result'

module GameRoomTournaments
  module OrdinaryMatchAdministration
    Data = Publication::Data
    private
    def build_administrative_preview(candidate, id, match, places: nil, forfeits: [], scores: nil, all_zero: false)
      reject_voided_return!(candidate,id,match)
      units = (match['unit_ids'] || match['players']).sort
      proof = administrative_boundary(candidate, id, match)
      game = @registry.build(candidate.fetch('game_id'))
      policy = game.tournament_small_point_policy(options: candidate.fetch('game_options'))
      verify_voided_pair_boundary!(candidate,id,match) if all_zero
      summary = AdministrativeResult.build(units: units, places: places, forfeits: forfeits,
        scores: scores, policy: policy, all_zero: all_zero)
      Data.freeze_tree(Data.copy({'kind'=>'ordinary-match-forfeit-v3', 'schedule_id'=>candidate['schedule_id'],
        'match_id'=>match['match_id'], 'leg'=>match['leg'], 'publication_ref'=>candidate['publication_ref'],
        'organizer'=>@owner, 'boundary'=>proof, 'summary'=>summary}))
    end

    # A waiting table is not a started game. Conversely, absence from the
    # membership-local history is never proof that an accepted start vanished.
    def administrative_boundary(candidate, id, match, start_rows: nil, binding: :read)
      binding = read_match_binding(candidate, id, match, nil) if binding == :read
      return {'status'=>'unbound'} unless binding
      raise OrdinaryMatchService::Blocked, :wrong_match_binding unless valid_binding?(binding, candidate, match)
      sessions = forfeit_native_sessions(candidate, id, match, binding, start_rows: start_rows)
      proof = {'binding_digest'=>binding_digest(binding)}
      return proof.merge('status'=>'unstarted') if sessions.empty?
      raise OrdinaryMatchService::Blocked, :game_state_unavailable unless @games
      raise OrdinaryMatchService::Blocked, :wrong_bound_session unless sessions.first['__id'] == binding['session_id']
      session = @games.session_by_id(binding['session_id'], table: binding['table'])
      snapshot = session && @games.snapshot_for(session, force_events: true)
      raise OrdinaryMatchService::Blocked, :game_state_unavailable unless snapshot
      game = @registry.build(binding['game_id'])
      replay = game.replay(snapshot.session, snapshot.events, @games)
      unless snapshot.session['__id'] == binding['session_id'] && snapshot.session['table_id'] == binding['table']['__id'] &&
          snapshot.session['game'] == binding['game_id'] && GameResult.valid_replay_history?(replay, snapshot.events) &&
          replay.players.map { |name| Data.account(name).downcase }.sort == binding['players'].map { |p| p['account'] }.sort
        raise OrdinaryMatchService::Blocked, :wrong_bound_session
      end
      unless replay.finished? || snapshot.session['__aborted'] || GameRoomTournamentPresence.ended?(snapshot.session)
        raise OrdinaryMatchService::Blocked, :match_in_progress
      end
      proof.merge('status'=>'ended', 'session_id'=>binding['session_id'], 'event_count'=>snapshot.events.size,
        'history_digest'=>Digest::SHA256.hexdigest(JSON.generate([snapshot.events, snapshot.session['__tournament_presence']])))
    end

    def validate_administrative_receipt!(document, candidate, match)
      keys = %w[boundary kind leg match_id organizer publication_ref schedule_id summary]
      unless document.keys.sort == keys && document['kind'] == 'ordinary-match-forfeit-v3' &&
          document['schedule_id'] == candidate['schedule_id'] && document['match_id'] == match['match_id'] &&
          document['leg'] == match['leg'] && document['publication_ref'] == candidate['publication_ref'] &&
          document['organizer'] == candidate.fetch('publication_ref').fetch('author').downcase
        raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt
      end
      proof = document['boundary']
      unless proof.is_a?(Hash) && case proof['status']
        when 'unbound' then proof.keys == ['status']
        when 'unstarted' then proof.keys.sort == %w[binding_digest status]
        when 'ended' then proof.keys.sort == %w[binding_digest event_count history_digest session_id status] &&
          Data.integer?(proof['event_count']) && Data.integer?(proof['session_id'], 1) &&
          /\A[0-9a-f]{64}\z/.match?(proof['history_digest'].to_s)
        else false
        end
        raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt
      end
      if proof.key?('binding_digest') && !/\A[0-9a-f]{64}\z/.match?(proof['binding_digest'].to_s)
        raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt
      end
      summary = document['summary']
      raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt unless summary.is_a?(Hash)
      policy = @registry.build(candidate['game_id']).tournament_small_point_policy(options: candidate['game_options'])
      expected = AdministrativeResult.build(units: (match['unit_ids'] || match['players']).sort,
        places: summary['places'], forfeits: summary.fetch('forfeits', []), scores: summary['scores'],
        policy: policy, all_zero: summary['resolution'] == 'all_zero')
      raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt unless summary == expected
      true
    rescue Publication::Invalid, ArgumentError, TypeError
      raise OrdinaryMatchService::Blocked, :invalid_forfeit_receipt
    end

    def verify_administrative_intent!(document, candidate, id, match)
      current, current_id = source!
      raise OrdinaryMatchService::Blocked, :source_changed unless current == candidate && current_id == id
      forfeit_match!(current, match['match_id'], match['leg'], candidate['schedule_id'])
      reject_voided_return!(candidate,id,match)
      validate_administrative_receipt!(document, candidate, match)
      accepted = forfeit_document(candidate, id, match)
      if accepted
        raise OrdinaryMatchService::Blocked, :conflicting_document unless accepted == document
        return true
      end
      raise OrdinaryMatchService::Blocked, :result_already_recorded if read_result_document(candidate, id, match)
      verify_voided_pair_boundary!(candidate,id,match) if document.dig('summary','resolution')=='all_zero'
      proof = administrative_boundary(candidate, id, match)
      raise OrdinaryMatchService::Blocked, :forfeit_preview_changed unless document['boundary'] == proof
      true
    end

    def paired_return(candidate,match)
      return unless candidate['format']=='knockout' && candidate.dig('knockout','rematch') && !candidate.dig('knockout','qualification')
      candidate['matches'].find do |other|
        other.values_at('match_id','leg')!=match.values_at('match_id','leg') &&
          (other['unit_ids'] || other['players']).sort==(match['unit_ids'] || match['players']).sort
      end
    end

    def reject_voided_return!(candidate,id,match)
      other=paired_return(candidate,match)
      return unless other
      receipt=forfeit_document(candidate,id,other)
      raise OrdinaryMatchService::Blocked,:result_already_recorded if receipt&.dig('summary','resolution')=='all_zero'
    end

    def verify_voided_pair_boundary!(candidate,id,match)
      other=paired_return(candidate,match)
      administrative_boundary(candidate,id,other) if other
    end
  end
end
