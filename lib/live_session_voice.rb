class GameRoomLiveSessionStore
  def table_voice(table, force: false)
    id = table_identifier(table)
    raise ArgumentError,'Invalid voice room' unless id
    ensure_current(id,force:force)
    GameRoomSnapshot.copy(table_for(id)&.fetch('voice',GameRoomTableVoice.empty))
  end

  def change_table_voice(table, data, actor:)
    id=table_identifier(table)
    raise ArgumentError,'Invalid voice room' unless id && same_user?(actor,endpoint.user)
    ensure_current(id,force:true)
    members=connected_users(id)
    raise ArgumentError,'Not at this table' unless members.any? { |member|same_user?(actor,member) }
    # The native owner may have changed before its ordinary screen refresh.
    # Record that authenticated handover through the shared control ledger
    # before authorizing the new owner's invitation reset.
    reconcile_control_owner(id)
    record=append_record(id,'room_voice',data,actor:actor)
    current=table_voice(table,force:true)
    {accepted:record && current && current['head']==record.message_id,voice:current}
  end
end
