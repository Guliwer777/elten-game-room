require_relative '../lobby_repository'
require_relative '../network_errors'
require_relative '../tournaments/match_target_guard'

module GameRoomUseCases
  # Existing membership policies also serve ordinary departure. These ports
  # intentionally call those policies again at the write boundary.
  InvitationMembership = Struct.new(:pending, :complete, :establish, :reconnect,
    :leave, :apply_role, :revoke, keyword_init: true)
  InvitationJoin = Struct.new(:result, :left_current, keyword_init: true)

  class AcceptInvitation
    CleanupFailure = Struct.new(:receipt, :primary_error, :cleanup_error, keyword_init: true)
    # Historia błędów tej instancji, nie „ostatni wynik”. Każdy wpis ma własny
    # attempt_id w receipt; odczytany snapshot nie zmienia się przy kolejnej próbie.
    attr_reader :cleanup_failures

    def initialize(lobby:, transport:, invitations:, membership:, user:, target_guard: nil, bound_membership: nil)
      @lobby, @transport, @invitations = lobby, transport, invitations
      @membership, @user = membership, user
      @target_guard, @bound_membership = target_guard, bound_membership
      @cleanup_failures = [].freeze
    end

    def lookup(invitation)
      user = @user.call.to_s
      current = account_guard(invitation)
      return [nil, nil, nil] unless current.call
      tables = @transport.discover_rooms(include_private: true)
      snapshots = tables.map do |table|
        @lobby.snapshot_for(table) || LobbyRepository::TableSnapshot.new(table: table,
          members: [@lobby.owner_of(table)], bots: @lobby.bots_for(table))
      end
      return [nil, nil, nil] unless current.call
      pending = @invitations.pending_by_id(invitation, user, tables: snapshots.map(&:table))
      return [nil, nil, nil] unless current.call
      snapshot = snapshots.find { |item| @lobby.table_id(item.table) == invitation.table_id }
      table = @lobby.current_table_for(user)
      current.call ? [pending, snapshot, table] : [nil, nil, nil]
    end

    def reconnect(invitation, binding: nil, consent: nil, admission: nil)
      unless binding.nil?
        outcome = join_bound(invitation, current: nil, binding: binding, consent: consent)
        return outcome.result.is_a?(LobbyRepository::JoinResult) && outcome.result.entered?
      end
      current = account_guard(invitation)
      return false unless current.call
      return nil if admission && !admission.call
      pending = @membership.pending.call(invitation.table)
      return false unless current.call
      return nil if admission && !admission.call
      accepted = @membership.reconnect.call(invitation.table)
      return false unless current.call
      if accepted
        @membership.apply_role.call(invitation.table)
        return false unless current.call
        @membership.complete.call(invitation.table, pending)
      end
      current.call && accepted
    end

    def join(invitation, current:, notification_id: nil, binding: nil, consent: nil, admission: nil)
      unless binding.nil?
        return join_bound(invitation, current: current, binding: binding, consent: consent)
      end
      left_current = false
      allowed = account_guard(invitation)
      refused = -> { InvitationJoin.new(result: :transport_failed, left_current: left_current) }
      user = @user.call.to_s.dup
      return refused.call unless allowed.call
      return nil if admission && !admission.call
      pending = @membership.pending.call(invitation.table)
      return refused.call unless allowed.call
      return nil if admission && !admission.call
      # Local visibility gates admission, not completion of an accepted RPC.
      # Account/endpoint guards still apply throughout the entire operation.
      status = @membership.establish.call(invitation.table)
      return refused.call unless allowed.call
      if status == :full
        return InvitationJoin.new(result: :table_full, left_current: false)
      elsif status == :closed
        @membership.revoke.call(invitation, notification_id: notification_id)
        return InvitationJoin.new(result: :table_closed, left_current: false)
      elsif ![:joined, :already_here].include?(status)
        return InvitationJoin.new(result: :transport_failed, left_current: false)
      end

      if current != nil
        begin
          left = @membership.leave.call(current)
          raise GameRoomNetworkErrors::GamePaused, 'The current table could not be left' if left == nil
          left_current = true
        rescue StandardError
          @transport.deactivate_table(table_id: invitation.table_id) if allowed.call
          raise
        end
      end
      return refused.call unless allowed.call

      joined = @lobby.join_table(invitation.table, user, announce: false)
      return refused.call unless allowed.call
      @membership.apply_role.call(joined.table) if joined.entered?
      return refused.call unless allowed.call
      if joined.entered?
        @membership.complete.call(joined.table, pending)
      elsif joined.status == :closed
        @transport.deactivate_table(table_id: invitation.table_id)
        return refused.call unless allowed.call
        @invitations.respond(invitation, recipient: user, response: 'expired')
        return refused.call unless allowed.call
        @membership.revoke.call(invitation, notification_id: notification_id)
      else
        @transport.deactivate_table(table_id: invitation.table_id)
      end
      return refused.call unless allowed.call
      InvitationJoin.new(result: joined, left_current: left_current)
    end

    private

    def account_guard(invitation)
      recipient = GameRoomInvitationIdentity.row(invitation)["recipient"].to_s
      GameRoomInvitationIdentity.account_guard(transport: @transport, user: @user, recipient: recipient)
    end

    # Port przyszłego właściciela, nie adapter obecnego deactivate_table(table_id).
    # establish zwraca receipt własnej próby; release musi WARUNKOWO porównać
    # scope/konto/native/participant/generację i attempt_id także przy retry.
    # NativeSDK 3.0.4 nie zapewnia tej umowy, więc domyślnie nie ma tego portu.
    def join_bound(invitation, current:, binding:, consent:)
      left_current = false
      refused = ->(code) { InvitationJoin.new(result: code, left_current: left_current) }
      return refused.call(:coordination_unavailable) unless @target_guard
      table = invitation.table
      check = -> { @target_guard.check(binding: binding, consent: consent,
        table: table, invitation_id: invitation.id, user: @user.call, invitation: invitation) }
      result = check.call
      return refused.call(result) unless result == :ok
      unless @bound_membership && @bound_membership.supports_owned_release?.equal?(true)
        return refused.call(:membership_ownership_unavailable)
      end
      pending = @membership.pending.call(table)
      result = check.call
      return refused.call(result) unless result == :ok
      attempt_id = SecureRandom.uuid
      receipt = @bound_membership.establish(table: table, binding: binding,
        account: consent.context['account'], attempt_id: attempt_id)
      receipt = copy_bound_receipt(receipt)
      unless bound_receipt?(receipt, binding, consent, attempt_id)
        return refused.call(:membership_unconfirmed)
      end
      entered = false
      begin
        result = check.call
        return refused.call(result) unless result == :ok
        if current
          result = check.call
          return refused.call(result) unless result == :ok
          left = @membership.leave.call(current)
          raise GameRoomNetworkErrors::GamePaused, 'The current table could not be left' if left.nil?
          left_current = true
        end
        result = check.call
        return refused.call(result) unless result == :ok
        joined = @lobby.join_table(table, @user.call, announce: false)
        result = check.call
        return refused.call(result) unless result == :ok
        if joined.entered?
          # Dokładną rolę ustanawia port bound, nie defaults zwykłego stołu.
          @membership.complete.call(joined.table, pending)
          result = check.call
          return refused.call(result) unless result == :ok
          entered = true
        end
        InvitationJoin.new(result: joined, left_current: left_current)
      rescue Exception => primary_error
        # Wyłącznie zachowanie i propagacja błędu TEJ operacji, nigdy $! rodzica.
        raise
      ensure
        release_bound(receipt, primary_error) unless entered || receipt['status'] == :already_here
      end
    end

    def copy_bound_receipt(receipt)
      return nil unless Hash === receipt && [:joined, :already_here].include?(receipt['status'])
      data = GameRoomTournaments::Publication::Data
      copy = data.copy(receipt.reject { |key, _value| key == 'status' })
      data.freeze_tree(copy.merge('status' => receipt['status']))
    rescue GameRoomTournaments::Publication::Invalid
      nil
    end

    def bound_receipt?(receipt, binding, consent, attempt_id)
      return false unless Hash === receipt && receipt.frozen? && [:joined, :already_here].include?(receipt['status'])
      expected = { 'attempt_id' => attempt_id, 'account' => consent.context['account'],
        'native_uuid' => binding.to_h['native_uuid'], 'table_id' => binding.to_h['table_id'],
        'scope' => binding.to_h['scope'] }
      expected.all? { |key, value| receipt[key].eql?(value) } &&
        %w[participant_id membership_generation].all? do |key|
          value = receipt[key]
          String === value && !value.empty? && value.bytesize <= 256
        end
    end

    class CleanupUnconfirmed < StandardError; end

    def release_bound(receipt, primary_error)
      result = @bound_membership.release(receipt)
      unless [:released, :superseded].include?(result)
        raise CleanupUnconfirmed, 'Niepotwierdzone sprzątanie własnej membership'
      end
    rescue Exception => cleanup_error
      failure = CleanupFailure.new(receipt: receipt, primary_error: primary_error, cleanup_error: cleanup_error).freeze
      @cleanup_failures = (@cleanup_failures + [failure]).freeze
      # Bez własnego primary zgłaszamy dokładny nowy błąd, również z rescue rodzica.
      # Przy primary ensure kończy się normalnie, nie przepodnosząc ani nie opakowując go.
      raise unless primary_error
    end
  end
end
