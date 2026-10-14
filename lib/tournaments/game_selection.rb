require_relative '../hidden_submissions'
module GameRoomTournaments
  # Detached selections may contain a game-owned private envelope. Its bytes
  # remain solely in the actor's private input archive.
  module GameSelection
    MARKER = '__private_envelope__'.freeze
    def self.encode(value)
      case value
      when HiddenSubmissions::Envelope
        {MARKER => encode(value.to_h)}
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = encode(item) }
      when Array
        value.map { |item| encode(item) }
      else value
      end
    end
    def self.decode(value)
      case value
      when Hash
        if value.keys == [MARKER]
          fields = value.fetch(MARKER)
          unless fields.is_a?(Hash) && fields.keys.sort == HiddenSubmissions::Envelope.members.map(&:to_s).sort
            raise ArgumentError, 'Invalid private envelope selection'
          end
          HiddenSubmissions::Envelope.new(**decode(fields).transform_keys(&:to_sym))
        else
          value.transform_values { |item| decode(item) }
        end
      when Array
        value.map { |item| decode(item) }
      else value
      end
    end
  end
end
