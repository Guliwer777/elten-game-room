# frozen_string_literal: true
require 'json'
require_relative 'table_round'

module GameRoomMahjong
  # Compact action payloads for the ordinary session event log. Account/seat
  # identity is resolved by its adapter; a payload cannot select its own actor.
  module TableEvents
    TYPES = {draw: 'd', replacement: 'r', discard: 'x', win: 'w', concealed_kong: 'k', added_kong: 'a', riichi: 'i', claim: 'c'}.freeze
    module_function

    def encode(action)
      unless action.is_a?(Hash) && action[:seat].is_a?(Integer) && action[:seat].between?(0, 3)
        raise ArgumentError, 'Invalid mahjong action actor'
      end
      payload = {'v'=>1, 'g'=>action[:generation], 'a'=>TYPES[action[:type]]}
      payload['t'] = action[:tile] if %i[discard concealed_kong added_kong riichi].include?(action[:type])
      payload['c'] = action[:choice].map(&:to_s).join(':') if action[:type] == :claim && action[:choice].is_a?(Array)
      decoded = decode(JSON.generate(payload), seat: action[:seat])
      raise ArgumentError, 'Invalid mahjong action payload' unless decoded == action
      JSON.generate(payload).freeze
    end

    def decode(value, seat:)
      return nil unless seat.is_a?(Integer) && seat.between?(0, 3) && value.is_a?(String) && value.bytesize <= 64
      payload = JSON.parse(value, max_nesting: 3)
      return nil unless payload.is_a?(Hash) && payload['v'].is_a?(Integer) && payload['v'] == 1 &&
        payload['g'].is_a?(Integer) && payload['g'].between?(0, (1 << 63) - 1)
      type = TYPES.key(payload['a'])
      return nil unless type
      extra = %i[discard concealed_kong added_kong riichi].include?(type) ? ['t'] : type == :claim ? ['c'] : []
      return nil unless payload.keys.sort == (['v', 'g', 'a'] + extra).sort
      action = {seat: seat, generation: payload['g'], type: type}
      if extra == ['t']
        limit = %i[discard riichi].include?(type) ? 135 : 33
        return nil unless payload['t'].is_a?(Integer) && payload['t'].between?(0, limit)
        action[:tile] = payload['t']
      elsif type == :claim
        choice = decode_choice(payload['c'])
        return nil unless choice
        action[:choice] = choice
      end
      action.freeze
    rescue JSON::ParserError, EncodingError
      nil
    end

    def decode_choice(value)
      return nil unless value.is_a?(String)
      return [value.to_sym].freeze if %w[pass win].include?(value)
      match = /\A(chow|pung|kong):(0|[1-9][0-9]?)\z/.match(value)
      return nil unless match
      kind = Integer(match[2], 10)
      return nil unless kind.between?(0, 33)
      return nil if match[1] == 'chow' && (kind >= 27 || kind % 9 > 6)
      [match[1].to_sym, kind].freeze
    end

    def selection(selection, round:, seat:)
      return nil unless selection.is_a?(Hash)
      action = {seat: seat, generation: round.flow.generation}
      if selection['kind'] == 'question' && selection['action'] == 'submit'
        id = selection['question_id']
        answer = selection['answer']
        return nil unless answer.is_a?(String)
        if id == "mahjong-claim:#{round.flow.generation}"
          choice = decode_choice(answer)
          return nil unless choice
          action.merge!(type: :claim, choice: choice)
        else
          return nil unless /\A(0|[1-9][0-9]{0,2})\z/.match?(answer)
          type = if id == "mahjong-discard:#{round.flow.generation}"
            :discard
          elsif id == "mahjong-kong:#{round.flow.generation}"
            :concealed_kong
          elsif id == "mahjong-added-kong:#{round.flow.generation}"
            :added_kong
          elsif id == "mahjong-riichi:#{round.flow.generation}"
            :riichi
          end
          return nil unless type
          action.merge!(type: type, tile: Integer(answer, 10))
        end
      elsif selection['kind'] == 'command'
        return nil unless selection['generation'].is_a?(Integer) && selection['generation'] == round.flow.generation
        type = { 'draw'=>:draw, 'replacement'=>:replacement, 'win'=>:win }[selection['action']]
        return nil unless type
        action[:type] = type
      else
        return nil
      end
      round.legal_action?(action) ? action.freeze : nil
    end

    def to_selection(action)
      # Validate before converting an internally planned action to UI input.
      encode(action)
      generation = action[:generation]
      if action[:type] == :claim
        {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-claim:#{generation}", 'answer'=>action[:choice].join(':')}.freeze
      elsif %i[discard concealed_kong added_kong riichi].include?(action[:type])
        name = {discard: 'discard', concealed_kong: 'kong', added_kong: 'added-kong', riichi: 'riichi'}.fetch(action[:type])
        {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-#{name}:#{generation}", 'answer'=>action[:tile].to_s}.freeze
      else
        {'kind'=>'command', 'action'=>action[:type].to_s, 'generation'=>generation}.freeze
      end
    end
  end
end
