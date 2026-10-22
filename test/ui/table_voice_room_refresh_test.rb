require_relative '../support/background_help_game_screen'

h,screen=screen_fixture(GameRoomGames::FourInARow.new)
room=LobbyRepository::TableSnapshot.new(**h.transports['Alice'].room_snapshot(h.table))
replay=h.replay('Alice')
layout=GameRoomLayout::Screen.new(view_spec:GameRoomLayout::ViewSpec.new,
  user_items:%w[Alice Bob],phase: :active)
screen.instance_variable_set(:@layout,layout)
layout.form.index=layout.form.fields.index(layout.chat)
layout.chat.set_text('unfinished chat')
layout.chat.index=4
identity=layout.voice_button.object_id

[
  [{'status'=>'ready','creator'=>'Alice'},'Disconnect voice conversation'],
  [{'status'=>'ready','creator'=>'Bob'},'Join voice conversation'],
  [{'status'=>'none'},'Create voice conversation']
].each do |voice,label|
  room.table=room.table.merge('voice'=>voice)
  screen.send(:apply_room_snapshot,layout.users,layout.history,replay,room,[])
  assert(layout.voice_button.label==label,'A table-only update retained the previous voice action label')
  assert(layout.voice_button.object_id==identity,'A voice update replaced the existing button')
  assert(layout.form.fields[layout.form.index].equal?(layout.chat),'A voice update stole focus')
  assert(layout.chat.text=='unfinished chat' && layout.chat.index==4,'A voice update lost the chat draft/caret')
end
puts 'PASS active table-only voice updates: creator/join/create labels, stable controls, focus and chat draft; no keyboard'
