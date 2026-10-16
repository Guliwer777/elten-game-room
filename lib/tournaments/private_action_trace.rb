require_relative 'game_selection'
module GameRoomTournaments
  # Replays the private reads seen by action_for, including a missing envelope
  # before its first creation. Later vault contents cannot change that input.
  class PrivateActionTrace
    attr_reader :calls
    def initialize(vault, calls: nil)
      @vault, @pending, @calls = vault, calls && LocalPrivateChoices.copy(calls), []
    end
    %i[reveal prepare discard].each do |operation|
      define_method(operation) do |**arguments|
        encoded = GameSelection.encode(arguments)
        if @pending
          call = @pending.shift
          unless call.is_a?(Hash) && call.keys.sort == %w[arguments operation result] && call['operation'] == operation.to_s && call['arguments'] == encoded
            raise HiddenSubmissions::StorageError, 'Private action trace differs from recorded calls'
          end
          result = GameSelection.decode(call['result'])
          if result.is_a?(HiddenSubmissions::Envelope) && !@vault.verify(result)
            raise HiddenSubmissions::StorageError, 'Invalid traced envelope'
          end
          result
        else
          result = @vault.public_send(operation, **arguments)
          raise HiddenSubmissions::StorageError, 'Private action trace too large' if @calls.size >= 64
          @calls << {'operation' => operation.to_s, 'arguments' => encoded, 'result' => GameSelection.encode(result)}
          result
        end
      end
    end
    def verify(envelope); @vault.verify(envelope); end
    def consumed?; !@pending || @pending.empty?; end
  end
end
