require_relative 'native_public_messages'

class NativeLiveSessionsBroker::View
  def send_private(recipient, packet, message_id:, **_options)
    raise EltenAPI::LiveSessions::SessionClosed if closed?
    (@sent_messages ||= []) << {recipient: recipient, packet: Marshal.load(Marshal.dump(packet))}
    return true if @hold_message
    sender = participants.find { |participant| participant.user == user }
    @core.views.reject(&:closed?).select { |view| view.user.casecmp?(recipient) }.each do |view|
      view.deliver_message(sender, packet, NativeLiveSessionsBroker::MessageInfo.new(recipient))
    end
    true
  end
end
