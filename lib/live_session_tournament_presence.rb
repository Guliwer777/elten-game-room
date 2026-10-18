require_relative 'tournament_presence'

class GameRoomLiveSessionStore
  module TournamentPresence
    def append_tournament_presence(session, data:, write_guard: nil, message_id: nil)
      table_id = table_identifier(session['table_id'])
      account = invitation_account_identity
      native = active_session(table_id)
      token = membership_token(table_id)
      return nil unless native && token && invitation_account_current?(account)
      if message_id
        accepted = records_for(table_id).find { |record| record.message_id == message_id && same_user?(record.sender, account.last) }
        if accepted
          raise ArgumentError, 'The tournament operation identity was reused' unless accepted.packet['kind'] == 'game_boundary' && accepted.packet['data'] == data
          return accepted
        end
      end
      organizer = data.dig('tournament_presence', 'origin') == 'organizer'
      guard = lambda do |captured|
        next false unless captured.equal?(native) && active_session(table_id).equal?(native) &&
          invitation_account_current?(account) && membership_token(table_id) == token
        ensure_current(table_id, force: true)
        dispatch_pending_events
        next false unless active_session(table_id).equal?(native) && invitation_account_current?(account) && !native.closed?
        authority = organizer ? native.metadata.dig('tournament_match', 'publication_ref', 'author') : owner_for(table_id)
        next false unless same_user?(account.last, authority) && (organizer || native.owner?)
        current = find_game_session(table_id)
        next false unless current && current['__id'] == session['__id'] &&
          current['__control_epoch'] == session['__control_epoch'] && current['__control_ready'] != false && !current['__aborted']
        next false if current['__frozen'] && current.dig('__tournament_presence', 'boundary_id') != current['__game_boundary']
        value = data['tournament_presence']
        next false unless value.is_a?(Hash) && current['__game_boundary'] == value['previous']
        # The same native visit must still see the same absent people. A late
        # callback never authorizes a decision against a newly joined player.
        absent = GameRoomTournamentPresence.active_players(current['__players'], current['__tournament_presence']).
          reject { |player| GameRoomParticipants.includes?(connected_users(table_id), player) }
        next false unless absent == value['absent']
        next false unless GameRoomTournamentPresence.transition(data, players: current['__players'],
          fixture: native.metadata['tournament_match'], previous: current['__tournament_presence'],
          boundary_id: current['__game_boundary'], epoch: current['__control_epoch'], revision: current['__game_revision'])
        !write_guard || write_guard.call(current)
      end
      append_record(table_id, 'game_boundary', data, actor: account.last, message_id: message_id, write_guard: guard)
    end

    private

    # Recovery has already read the native log. A confirmed original is handled
    # by the usual UUID path. If membership changed while an unacknowledged
    # assertion was in flight, do not replay it against the returning player.
    # Keep it immutable and order one zero-time correction against the SAME
    # previous boundary. Whichever arrives first wins; the later CAS is inert.
    def reconcile_tournament_presence_write(table_id, pending)
      value = pending.packet.dig('data', 'tournament_presence')
      return false unless pending.uncertain && pending.packet['kind'] == 'game_boundary' && value.is_a?(Hash)
      current = find_game_session(table_id)
      return false unless current && current['__control_ready'] != false
      return true if settle_tournament_presence_write(table_id, pending, current)
      return false if value['origin'] == 'organizer'
      native = active_session(table_id)
      account = invitation_account_identity
      return false unless native && native.owner? && same_user?(pending.sender, account.last) && invitation_account_current?(account)
      absent = GameRoomTournamentPresence.active_players(current['__players'], current['__tournament_presence']).
        reject { |player| GameRoomParticipants.includes?(connected_users(table_id), player) }
      return false unless pending.resolution || absent != value['absent']
      pending.resolution ||= tournament_presence_resolution(table_id, pending, current, native, account, absent)
      write_record(table_id, pending.resolution)
      ensure_current(table_id, force: true)
      current = find_game_session(table_id)
      return true if current && settle_tournament_presence_write(table_id, pending, current)
      raise GameRoomNetworkErrors::UncertainWrite, 'The presence correction has not been confirmed'
    end

    def settle_tournament_presence_write(table_id, pending, current)
      value = pending.packet['data']['tournament_presence']
      return false if current['__id'] == pending.packet['data']['session_id'] &&
        current['__control_epoch'] == value['epoch'] && current['__game_boundary'] == value['previous'] &&
        (value['version'] == 1 || current['__game_revision'] == value['revision'])
      # A validated successor/epoch makes the original CAS permanently stale,
      # even if its request is delivered later. An empty read never does this.
      @mutex.synchronize do
        room = @rooms[table_id]
        room.pending_move = nil if room&.pending_move.equal?(pending)
      end
      true
    end

    def tournament_presence_resolution(table_id, pending, current, native, account, absent)
      value = pending.packet['data']['tournament_presence']
      token = membership_token(table_id)
      data = GameRoomTournamentPresence.data(session: current, fixture: value['fixture'],
        binding_digest: value['binding_digest'], absent: absent, elapsed_ms: 0)
      guard = lambda do |captured|
        next false unless captured.equal?(native) && invitation_account_current?(account) &&
          active_session(table_id).equal?(native) && membership_token(table_id) == token && native.owner? && !native.closed?
        ensure_current(table_id, force: true)
        fresh = find_game_session(table_id)
        fresh && invitation_account_current?(account) && active_session(table_id).equal?(native) && native.owner? &&
          fresh['__control_ready'] != false && fresh['__id'] == current['__id'] &&
          fresh['__control_epoch'] == value['epoch'] && fresh['__game_boundary'] == value['previous']
      end
      GameRoomSessionContracts::PendingWrite.new(message_id: SecureRandom.uuid,
        packet: GameRoomEventProtocol.record_packet(kind: 'game_boundary', actor: account.last, data: data),
        sender: account.last, writing: false, write_guard: guard)
    end
  end
  include TournamentPresence
end
