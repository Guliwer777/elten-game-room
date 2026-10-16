require_relative 'local_private_choices'
require_relative 'private_action_trace'
module GameRoomTournaments
  module LocalPrivateMoveInput
    def private_move_input(execution, receipt)
      return nil unless receipt.key?('selection_ref')
      unless receipt['selection'] == {'kind' => 'private', 'action' => 'submitted'} &&
          receipt['selection_ref'].is_a?(String) && receipt['selection_ref'].match?(/\A[0-9a-f]{64}\z/)
        raise Publication::Invalid, :sandbox_corrupt
      end
      actor, session_id = receipt.values_at('account', 'session_id')
      scope = CoordinationContract.digest(execution['request'])
      private_identity = LocalPrivateChoices.identity(backend_identity: identity, scope_digest: scope, actor: actor, session_id: session_id)
      private_store = LocalPrivateChoices::Storage.new(directory: File.join(directory, 'private-inputs', private_identity),
        identity: private_identity, actor: actor, session_id: session_id, guard: @guard)
      vault = LocalPrivateChoices::ReadOnlyVault.new(private_store.read, actor: actor, session_id: session_id)
      envelope = vault.reveal(session_id: session_id, round_id: LocalPrivateChoices.input_round(receipt['id']),
        user: actor, commitment: receipt['selection_ref'])
      unless envelope && envelope.payload.is_a?(Hash) &&
          [%w[selection], %w[calls selection]].include?(envelope.payload.keys.sort) && vault.verify(envelope)
        raise Publication::Invalid, :sandbox_corrupt
      end
      if envelope.payload.key?('calls')
        calls = envelope.payload['calls']
        raise Publication::Invalid, :sandbox_corrupt unless calls.is_a?(Array) && calls.size <= 64
        vault = PrivateActionTrace.new(vault, calls: calls)
      end
      {selection: envelope.payload['selection'], vault: vault}
    rescue HiddenSubmissions::StorageError => error
      raise Publication::Invalid.new(:sandbox_corrupt), cause: error
    end
  end
end
