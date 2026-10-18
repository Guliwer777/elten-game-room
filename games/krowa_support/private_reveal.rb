require "securerandom"
require_relative "../../lib/hidden_submissions"

module GameRoomGames
  # Ephemeral, addressed delivery, separate from the public move history.
  # A surrendered player requests again after reconnecting; no shared secret
  # is sent to a player who is still racing or to an observer.
  class KrowaPrivateReveal
    attr_reader :word

    def initialize(game, transport, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @game, @transport, @clock = game, transport, clock
      @last_request = -Float::INFINITY
    end

    def due?
      return false unless @context && @transport
      @transport.private_game_messages_pending?(@context.table_id, @context.session_id) ||
        (@request_needed && @clock.call - @last_request >= 5)
    end

    def update(replay, viewer, context)
      @context = context
      key = [context.session_id, replay.state[:round], replay.state[:commitment]]
      if @key != key
        @key, @word, @last_request = key, nil, -Float::INFINITY
      end
      state = replay.state
      @request_needed = false
      return unless @transport && state[:options]["variant"] == "race"
      player = replay.players.find { |name| same?(name, viewer) }
      surrendered = player && state[:surrender_words].key?(player)
      host = context.table_owner.to_s.empty? ? replay.players.first : context.table_owner
      @request_needed = surrendered && !@word && !replay.finished?
      if surrendered && same?(viewer, host)
        secret = secret_for(replay, context)
        @word = secret.payload["word"] if secret
      end
      @request_needed = surrendered && !@word && !replay.finished?
      @transport.take_private_game_messages(context.table_id, context.session_id).each do |message|
        packet, sender = message.values_at(:payload, :sender)
        next unless packet["game"] == "krowa" && packet["round"] == state[:round] &&
          packet["commitment"] == state[:commitment]
        if packet["action"] == "request" && same?(viewer, host)
          target = replay.players.find { |name| same?(name, sender) }
          next unless target && state[:surrender_words].key?(target)
          secret = secret_for(replay, context)
          next unless secret
          send_packet(target, "solution", state, {"payload" => secret.payload, "nonce" => secret.nonce})
        elsif packet["action"] == "solution" && surrendered && same?(sender, host)
          payload = packet["payload"]
          next unless payload.is_a?(Hash) && payload.keys.sort == %w[day word] &&
            payload["day"] == state[:day] && payload["word"].is_a?(String) &&
            payload["word"].length == state[:length] && packet["nonce"].is_a?(String) &&
            HiddenSubmissions::Commitment.valid?(payload: payload, nonce: packet["nonce"], commitment: state[:commitment])
          @word = payload["word"]
          @request_needed = false
        end
      end
      if @request_needed && @clock.call - @last_request >= 5
        @last_request = @clock.call
        send_packet(host, "request", state) unless same?(viewer, host)
      end
      @word
    rescue HiddenSubmissions::StorageError
      # The client reports the read failure. Retain a bounded retry for a
      # surrendered host too; no further public move may arrive to wake it.
      @last_request = @clock.call
      raise
    end

    private

    def same?(left, right); left.to_s.casecmp(right.to_s).zero?; end

    def secret_for(replay, context)
      secret = context.hidden_submissions.reveal(session_id: context.session_id,
        round_id: "krowa:#{replay.state[:round]}", user: replay.players.first,
        commitment: replay.state[:commitment])
      secret if secret && context.hidden_submissions.verify(secret)
    end

    def send_packet(recipient, action, state, values = {})
      @transport.send_private_game(table_id: @context.table_id, session_id: @context.session_id,
        recipient: recipient, message_id: SecureRandom.uuid,
        payload: {"game" => "krowa", "action" => action, "round" => state[:round],
          "commitment" => state[:commitment]}.merge(values))
    end
  end
end
