require "json"
require "zlib"
require "base64"
require "digest"
require_relative "game_event_protocol"
require_relative "../games/contracts"

# Large local selections still use the ordinary, atomic ActionPlan transport.
# A logical move is applied only after every consecutive fragment is verified.
# No partial meld becomes public game state and no fragment is a separate write.
module GameRoomActionPayload
  CHUNK = 46
  MAX_PARTS = GameRoomEventProtocol::MAX_EVENTS
  MAX_JSON = 12_000
  module_function

  # Used at the ordinary write/validation boundary as well as by replay.
  # This decodes a complete logical action; a prefix is never an action.
  def data_from_commands(commands, action)
    rows = commands.map { |command| GameRoomEventProtocol.normalized(command) }
    reader = Object.new
    def reader.actor_of(_event, _session); ''; end
    decoded = []
    each(rows, action, reader, {}) { |data, _, batch| decoded << data if batch.length == rows.length }
    decoded.one? ? decoded.first : nil
  end

  def commands(action, data)
    json = JSON.generate(data)
    raise ArgumentError, "Game action payload is too large" if json.bytesize > MAX_JSON
    encoded = Base64.strict_encode64(Zlib::Deflate.deflate(json))
    parts = encoded.scan(/.{1,#{CHUNK}}/)
    raise ArgumentError, "Game action has too many fragments" if parts.length > MAX_PARTS
    digest = Digest::SHA256.hexdigest(encoded)[0, 10]
    parts.each_with_index.map do |part, index|
      GameRoomGames::EventCommand.new(action: action,
        value: "#{index.to_s(36)}.#{parts.length.to_s(36)}.#{digest}.#{part}")
    end
  end

  def each(events, action, repository, session, controls: false)
    batch = []
    actor = nil
    header = nil
    events.each do |event|
      match = /\A([0-9a-z]+)\.([0-9a-z]+)\.([0-9a-f]{10})\.([A-Za-z0-9+\/=]+)\z/.match(event["value"].to_s)
      who = repository.actor_of(event, session)
      unless event["action"].to_s == action && match
        batch = []; header = nil
        yield(nil, who, [event]) if controls && event['action'].to_s != action
        next
      end
      index, count = match[1].to_i(36), match[2].to_i(36)
      if index == 0
        batch = []; actor = who; header = [count, match[3]]
      end
      unless count.between?(1, MAX_PARTS) && header == [count, match[3]] && actor == who && index == batch.length
        batch = []; header = nil
        next
      end
      batch << [event, match[4]]
      next unless batch.length == count
      parsed = nil
      begin
        encoded = batch.map(&:last).join
        if Digest::SHA256.hexdigest(encoded)[0, 10] == header[1]
          # Bounded streaming inflation also rejects a small zip-bomb payload.
          inflater = Zlib::Inflate.new
          json = +""
          Base64.strict_decode64(encoded).bytes.each_slice(32) do |bytes|
            json << inflater.inflate(bytes.pack("C*"))
            raise ArgumentError, "Inflated action is too large" if json.bytesize > MAX_JSON
          end
          raise ArgumentError, "Incomplete compressed action" unless inflater.finished?
          parsed = JSON.parse(json)
        end
      rescue JSON::ParserError, Zlib::Error, ArgumentError
        # Corrupt/untrusted history cannot apply a partial action.
      ensure
        inflater.close if inflater && !inflater.closed?
        inflater = nil
      end
      yield(parsed, actor, batch.map(&:first)) if parsed.is_a?(Hash)
      batch = []; header = nil
    end
  end
end
