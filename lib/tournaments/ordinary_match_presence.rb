require_relative '../tournament_presence'

module GameRoomTournaments
  module OrdinaryMatchPresence
    Data = Publication::Data
    # The attachment is sufficient to propose a pause, never a sporting
    # decision. A terminal decision additionally re-reads the plan/result and
    # binding on the existing execution worker immediately before the push.
    def presence_context(table, session, replay, events, decisive:)
      row = @lock.synchronize { @bindings[table['__id']] }
      return nil unless row && row[0]['table']['__live_session_id'] == table['__live_session_id'] &&
        session['__id'] == row[0]['session_id'] && !@closed
      account!
      binding, candidate, id, match = row
      return nil unless GameResult.valid_replay_history?(replay, events) &&
        replay.players.map { |name| Data.account(name).downcase }.sort == binding['players'].map { |person| person['account'] }.sort
      if decisive
        current, current_id = source!
        raise OrdinaryMatchService::Blocked, :source_changed unless current == candidate && current_id == id
        raise OrdinaryMatchService::Blocked, :result_already_recorded if forfeit_document(candidate, id, match) || read_result_document(candidate, id, match)
        raise OrdinaryMatchService::Blocked, :wrong_match_binding unless read_match_binding(candidate, id, match, nil) == binding
      end
      {'fixture'=>binding['table'].fetch('tournament_match'),
        'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding)), 'individual'=>!match.key?('unit_ids')}
    end
  end
end
