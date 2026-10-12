# frozen_string_literal: true

require "base64"
require "json"
require "zlib"

module GameRoomDuckRacing
  # Duck-only wire codec. The canonical answer and its salted commitment are
  # unchanged: compress their complete envelope once, then page these bytes.
  # These are generous transport/memory bounds, NOT Simon gameplay limits.
  # Exceeding them must cancel the challenge without a score/feather transfer.
  module PrivateTraceStream
    class InvalidStream < ArgumentError; end
    class CapacityError < StandardError; end

    VERSION = 2
    CODEC = "zlib-trace-1".freeze
    LEGACY_CODEC = "zlib-json-1".freeze
    CODECS = [CODEC, LEGACY_CODEC].freeze
    INPUT_FIELDS = %w[kind value press_id repeat other playback_id onsets_ms].freeze
    MAX_EXPANDED_BYTES = 8 * 1024 * 1024
    MAX_COMPRESSED_BYTES = 2 * 1024 * 1024
    EXPANSION_RATIO = 256
    EXPANSION_ALLOWANCE = 64 * 1024
    PAGE_KEYS = %w[version codec session round seat total unpacked_bytes offset data].sort.freeze
    WIRE_FIELDS = %w[version codec session round seat total unpacked_bytes offset data].freeze
    CACHE_KEYS = %w[version codec commitment unpacked_bytes data].sort.freeze
    Stream = Struct.new(:bytes, :unpacked_bytes, :codec, keyword_init: true)

    module_function

    def encode(envelope)
      json = JSON.generate("nonce" => envelope.nonce, "payload" => envelope.payload)
      raise CapacityError, "The private answer exceeds the transport memory budget" if json.bytesize > MAX_EXPANDED_BYTES
      # Preserve every input and its exact time. Repeated field names and
      # ever-growing absolute timestamps/press IDs need not travel on the wire.
      # The salted commitment still covers the original, unmodified payload.
      json = JSON.generate(compact(envelope))
      bytes = Zlib::Deflate.deflate(json)
      check_size!(bytes.bytesize, json.bytesize)
      Stream.new(bytes: bytes.freeze, unpacked_bytes: json.bytesize, codec: CODEC).freeze
    end

    def cache_payload(stream, commitment)
      {"version" => VERSION, "codec" => stream.codec || LEGACY_CODEC, "commitment" => commitment,
        "unpacked_bytes" => stream.unpacked_bytes, "data" => Base64.strict_encode64(stream.bytes)}
    end

    def from_cache(data, envelope)
      unless data.is_a?(Hash) && data.keys.all? { |key| key.is_a?(String) } && data.keys.sort == CACHE_KEYS && data["version"] == VERSION &&
          CODECS.include?(data["codec"]) && data["commitment"] == envelope.commitment
        raise InvalidStream, "Invalid stored private stream"
      end
      bytes = decode_bytes(data["data"], MAX_COMPRESSED_BYTES)
      check_size!(bytes.bytesize, data["unpacked_bytes"])
      stream = Stream.new(bytes: bytes.freeze, unpacked_bytes: data["unpacked_bytes"], codec: data["codec"]).freeze
      original = decode(stream)
      unless original["nonce"] == envelope.nonce && original["payload"] == envelope.payload
        raise InvalidStream, "The stored private stream differs from its answer"
      end
      stream
    end

    def page(stream, payload, offset, count)
      unless offset.is_a?(Integer) && count.is_a?(Integer) && offset >= 0 && count.positive? &&
          offset + count <= stream.bytes.bytesize
        raise InvalidStream, "Invalid private byte range"
      end
      {"version" => VERSION, "codec" => stream.codec || LEGACY_CODEC, "session" => payload.fetch("session"),
        "round" => payload.fetch("round").dup, "seat" => payload.fetch("seat"),
        "total" => stream.bytes.bytesize, "unpacked_bytes" => stream.unpacked_bytes,
        "offset" => offset, "data" => Base64.strict_encode64(stream.bytes.byteslice(offset, count))}
    end

    def normalize_page(page, session_id:, round_id:, seat:)
      if page.is_a?(Array)
        return nil unless page.length == WIRE_FIELDS.length
        page = WIRE_FIELDS.zip(page).to_h
      end
      return nil unless page.is_a?(Hash) && page.keys.all? { |key| key.is_a?(String) } && page.keys.sort == PAGE_KEYS &&
        page["version"] == VERSION && CODECS.include?(page["codec"]) && page["session"] == session_id &&
        page["round"] == round_id && page["seat"] == seat && page["offset"].is_a?(Integer) && page["offset"] >= 0

      check_size!(page["total"], page["unpacked_bytes"])
      bytes = decode_bytes(page["data"], page["total"])
      return nil if bytes.empty? || page["offset"] + bytes.bytesize > page["total"]

      page.to_h { |key, value| [key, value.is_a?(String) ? value.dup : value] }
    rescue InvalidStream, CapacityError
      nil
    end

    # The enclosing action already provides atomic fragment framing. Use a
    # fixed field order for its page rather than repeating nine JSON names
    # on every small native write. No identity/scope field is omitted.
    def wire_page(page)
      WIRE_FIELDS.map { |field| page.fetch(field) }
    end

    def page_bytes(page)
      decode_bytes(page.fetch("data"), MAX_COMPRESSED_BYTES)
    end

    def page_size(page)
      page_bytes(page).bytesize
    end

    def shrink_page(page)
      bytes = page_bytes(page)
      raise CapacityError, "A private stream byte cannot fit in an event page" if bytes.bytesize <= 1

      page.merge("data" => Base64.strict_encode64(bytes.byteslice(0, bytes.bytesize / 2)))
    end

    def decode(stream)
      bytes, expected = stream.bytes, stream.unpacked_bytes
      codec = stream.codec || LEGACY_CODEC
      raise InvalidStream, "Unknown private stream codec" unless CODECS.include?(codec)
      check_size!(bytes.bytesize, expected)
      inflater, json = Zlib::Inflate.new, +""
      offset = 0
      while offset < bytes.bytesize
        # Block inflation emits bounded chunks instead of allocating a complete
        # expansion before checking its size. Stop at the declared exact size.
        inflater.inflate(bytes.byteslice(offset, 1024)) do |chunk|
          raise InvalidStream, "Private stream expansion exceeds its declared size" if json.bytesize + chunk.bytesize > expected
          json << chunk
        end
        offset += 1024
      end
      unless inflater.finished? && inflater.total_in == bytes.bytesize && json.bytesize == expected
        raise InvalidStream, "Incomplete or trailing private stream data"
      end
      json.force_encoding(Encoding::UTF_8)
      raise InvalidStream, "Invalid private stream UTF-8" unless json.valid_encoding?
      data = JSON.parse(json)
      keys = codec == CODEC ? %w[nonce payload trace] : %w[nonce payload]
      unless data.is_a?(Hash) && data.keys.sort == keys && data["payload"].is_a?(Hash) &&
          data["nonce"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(data["nonce"]) && JSON.generate(data) == json
        raise InvalidStream, "Invalid compressed private envelope"
      end
      codec == CODEC ? expand(data) : data
    rescue JSON::ParserError, Zlib::Error => error
      raise InvalidStream, "Invalid compressed private stream: #{error.message}"
    ensure
      inflater.close if inflater && !inflater.closed?
    end

    def compact(envelope)
      previous_time = previous_press = 0
      rows = envelope.payload.fetch("trace").map do |at, input|
        raise InvalidStream, "Invalid private input fields" unless (input.keys - INPUT_FIELDS).empty?
        mask, values = 0, []
        INPUT_FIELDS.each_with_index do |field, index|
          next unless input.key?(field)
          mask |= 1 << index
          value = input[field]
          if field == "press_id"
            value, previous_press = value - previous_press, value
          end
          values << value
        end
        delta, previous_time = at - previous_time, at
        [delta, mask, *values]
      end
      {"nonce" => envelope.nonce, "payload" => envelope.payload.reject { |key, _| key == "trace" }, "trace" => rows}
    end
    private_class_method :compact

    def expand(data)
      rows, payload = data["trace"], data["payload"]
      unless rows.is_a?(Array) && !payload.key?("trace")
        raise InvalidStream, "Invalid compact private trace"
      end
      bytes = JSON.generate("nonce" => data["nonce"], "payload" => payload.merge("trace" => [])).bytesize
      time = press = 0
      trace = rows.each_with_index.map do |row, index|
        unless row.is_a?(Array) && row.length >= 2 && row[0].is_a?(Integer) && row[0] >= 0 &&
            row[1].is_a?(Integer) && row[1].between?(1, (1 << INPUT_FIELDS.length) - 1) &&
            row.length == 2 + row[1].digits(2).sum
          raise InvalidStream, "Invalid compact private input"
        end
        time += row[0]
        input, position = {}, 2
        INPUT_FIELDS.each_with_index do |field, index|
          next if row[1] & (1 << index) == 0
          value = row[position]
          position += 1
          if field == "press_id"
            raise InvalidStream, "Invalid compact press identity" unless value.is_a?(Integer)
            press += value
            value = press
          end
          input[field] = value
        end
        entry = [time, input]
        bytes += JSON.generate(entry).bytesize + (index.zero? ? 0 : 1)
        raise CapacityError, "The private answer exceeds the transport memory budget" if bytes > MAX_EXPANDED_BYTES
        entry
      end
      {"nonce" => data["nonce"], "payload" => payload.merge("trace" => trace)}
    end
    private_class_method :expand

    def decode_bytes(encoded, limit)
      unless encoded.is_a?(String) && encoded.ascii_only? && encoded.bytesize <= ((limit + 2) / 3) * 4
        raise InvalidStream, "Invalid private stream encoding"
      end
      bytes = Base64.strict_decode64(encoded)
      unless bytes.bytesize <= limit && Base64.strict_encode64(bytes) == encoded
        raise InvalidStream, "Invalid private stream encoding"
      end
      bytes
    rescue ArgumentError => error
      raise InvalidStream, error.message
    end
    private_class_method :decode_bytes

    def check_size!(compressed, expanded)
      unless compressed.is_a?(Integer) && compressed.positive? && expanded.is_a?(Integer) && expanded.positive?
        raise InvalidStream, "Invalid private stream size"
      end
      unless compressed <= MAX_COMPRESSED_BYTES && expanded <= MAX_EXPANDED_BYTES &&
          expanded <= [EXPANSION_ALLOWANCE, compressed * EXPANSION_RATIO].max
        raise CapacityError, "The private answer exceeds the transport memory budget"
      end
    end
    private_class_method :check_size!
  end
end
