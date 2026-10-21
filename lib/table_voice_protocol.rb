# frozen_string_literal: true
module GameRoomTableVoice
  CLAIM_SECONDS = 30
  module_function
  def empty; {'head'=>'','status'=>'none'}; end
  def valid?(value)
    return false unless value.is_a?(Hash) && value['head'].is_a?(String) && value['head'].bytesize <= 128
    case value['status']
    when 'none' then value.keys.sort == %w[head status]
    when 'preparing'
      value.keys.sort == %w[creator head started_at status] && person?(value['creator']) &&
        value['started_at'].is_a?(Integer) && value['started_at'] >= 0 && !value['head'].empty?
    when 'ready'
      value.keys.sort == %w[channel_id creator head name password status] && person?(value['creator']) &&
        value['channel_id'].is_a?(Integer) && value['channel_id'].positive? && !value['head'].empty? &&
        text?(value['name'],100) && text?(value['password'],128,empty:true)
    else false
    end
  end
  def person?(value); text?(value,64); end
  def text?(value,limit,empty:false)
    value.is_a?(String) && (empty || !value.empty?) && value.length <= limit && !value.match?(/[\r\n\0]/)
  end
  def transition(previous, record, owner:)
    previous ||= empty
    data = record.packet['data']
    return unless valid?(previous) && person?(record.sender) && person?(record.packet['actor']) &&
      data.is_a?(Hash) && data['previous'] == previous['head'] &&
      record.message_id.is_a?(String) && !record.message_id.empty? &&
      GameRoomParticipants.same?(record.sender,record.packet['actor'])
    case data['operation']
    when 'claim'
      return unless data.keys.sort == %w[operation previous] &&
        (previous['status']=='none' || previous['status']=='preparing' && record.created_at.to_i - previous['started_at'] >= CLAIM_SECONDS)
      {'head'=>record.message_id,'status'=>'preparing','creator'=>record.sender,'started_at'=>record.created_at.to_i}
    when 'publish'
      return unless data.keys.sort == %w[channel_id name operation password previous] &&
        previous['status']=='preparing' && GameRoomParticipants.same?(record.sender,previous['creator'])
      value=data.slice('channel_id','name','password').merge('head'=>record.message_id,'status'=>'ready','creator'=>record.sender)
      value if valid?(value)
    when 'clear'
      return unless data.keys.sort == %w[operation previous] &&
        (GameRoomParticipants.same?(record.sender,previous['creator']) || GameRoomParticipants.same?(record.sender,owner))
      {'head'=>record.message_id,'status'=>'none'}
    end
  end
end
