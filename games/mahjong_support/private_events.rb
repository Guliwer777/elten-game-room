# frozen_string_literal: true
require_relative 'table_events'

module GameRoomMahjong
  module PrivateEvents
    module_function

    # Same logical actions as TableEvents. An array leaves enough space for
    # the exact physical packet without exceeding the shared 64-byte dialect.
    def encode(action, hand:, cards: [])
      original = JSON.parse(TableEvents.encode(action))
      value = JSON.generate([1, hand, original['g'], original['a'], original['t'] || original['c'], cards])
      raise ArgumentError, 'Private Mahjong move exceeds the action limit' if value.bytesize > 64
      raise ArgumentError, 'Invalid private Mahjong packet' unless decode(value, seat: action[:seat], hand: hand)
      value
    end

    def decode(value, seat:, hand:)
      return nil unless value.is_a?(String) && value.bytesize <= 64
      data = JSON.parse(value, max_nesting: 4)
      return nil unless data.is_a?(Array) && data.size == 6 && data[0] == 1 && data[1] == hand
      _, _, generation, code, argument, cards = data
      payload = {'v'=>1, 'g'=>generation, 'a'=>code}
      type = TableEvents::TYPES.key(code)
      if %i[discard concealed_kong added_kong riichi].include?(type)
        payload['t'] = argument
      elsif type == :claim
        payload['c'] = argument
      else
        return nil unless argument.nil?
      end
      action = TableEvents.decode(JSON.generate(payload), seat: seat)
      return nil unless action && cards.is_a?(Array) && cards.size <= 4 && cards.uniq == cards &&
        cards.all? { |tile| tile.is_a?(Integer) && tile.between?(0, 135) }
      expected = packet_kinds(action)
      kinds = cards.map { |tile| Tiles.kind(tile) }
      if type == :claim && !%i[pass win].include?(action[:choice].first)
        return nil unless kinds.size == expected.size - 1 && kinds.tally.all? { |kind, count| expected.count(kind) >= count }
      else
        return nil unless expected.nil? ? cards.empty? : kinds.sort == expected.sort
      end
      return nil if %i[discard riichi].include?(type) && cards != [action[:tile]]
      [action, cards.freeze]
    rescue JSON::ParserError, EncodingError
      nil
    end

    def packet_kinds(action)
      case action[:type]
      when :discard, :riichi then [Tiles.kind(action[:tile])]
      when :concealed_kong then Array.new(4, action[:tile])
      when :added_kong then [action[:tile]]
      when :win then nil
      when :claim
        choice = action[:choice]
        return nil if choice == [:win]
        return [] if choice == [:pass]
        kinds = Hand.tiles_for(choice).dup
        # The claimed discard is supplied by the public flow, not the hand.
        # It is removed by packet_for/valid_packet? at the adapter boundary.
        kinds
      else []
      end
    end

    def winning?(action)
      action[:type] == :win || action[:type] == :claim && action[:choice] == [:win]
    end
  end
end
