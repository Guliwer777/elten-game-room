require_relative '../support/localization'
runtime = GameRoomTestLocalization.use_language('pl')
Programs.with_runtime(runtime) { require_relative '../support/table_watch_runtime' }

Notice2.class_eval do
  def presentation(**options); FakePresentation.new(options); end
end
settings = GameRoomPreferences.normalize({}, EltenGameRoom::GAME_REGISTRY.ids)
EltenGameRoom.define_singleton_method(:normalized_settings) { settings }
EltenGameRoom.define_singleton_method(:sound_asset_path) { |name| name }
now = 2_000_000_000
uuid = EltenGameRoom.server_app_uuid
EltenGameRoom.instance_variable_set(:@table_watch_receiver,
  GameRoomTableWatch::Receiver.new(user: 'Alice', games: EltenGameRoom::GAME_REGISTRY.ids,
    uuid: uuid, clock: -> { now }))
app = EltenGameRoom.new
lobby = Object.new
def lobby.owner_of(row); row.fetch('owner'); end
def lobby.capacity_of(_row); 8; end
def lobby.playing?(_row); false; end
app.instance_variable_set(:@lobby, lobby)
app.define_singleton_method(:widget_table_available?) { |_snapshot| true }

examples = {
  'audio_ball' => [{'difficulty'=>3,'sets_to_win'=>3}, 'Normalny, do 3 wygranych setów'],
  'categories' => [{'answer_language'=>'pl','target_score'=>100}, 'Polski, 100 punktów'],
  'spades' => [{'quicksand'=>true,'team_size'=>2,'score_limit'=>300}, 'Quicksand, 300 punktów'],
  'uno' => [{'score_limit'=>500}, '500 punktów']
}
examples.each_with_index do |(id, (options, expected)), index|
  game = EltenGameRoom::GAME_REGISTRY.build(id)
  row = {'__id'=>index+10,'owner'=>'Bob','game'=>id,'game_options'=>JSON.generate(options)}
  snapshot = WidgetSnapshot.new(table: row, members: ['Bob'])
  payload = GameRoomTableVariant.payload(game, options)
  join = app.send(:table_join_label, snapshot)
  widget = app.send(:widget_table_label, snapshot)
  assert(join.end_with?(expected), "Join variant differs: #{join}")
  assert(widget.end_with?(join), "Widget lost existing table label: #{widget}")
  %w[game_room.invitation game_room.table_created].each do |type|
    type = GameRoomTableWatch::TYPE if type == 'game_room.table_created'
    notice = Notice2.new(id: index+100, app_uuid: uuid, sender: 'Bob', type: type,
      metadata: {'format'=>1,'game'=>id,'sender'=>'Bob','table_name'=>'Room','table_id'=>index+10,
        'live_session_id'=>"variant-#{index}",'created_at'=>now,'expires_at'=>now+300,'variant'=>payload})
    fields = EltenGameRoom.map_notification(notice).instance_variable_get(:@options)
    assert([fields[:title],fields[:body]].join(' ').include?(expected), "Notification variant differs: #{fields}")
  end
end
technical_name = 'Alice — Bob / 1 [c9ae9b6f4805]'
invitation_metadata = {
  'game'=>'uno', 'sender'=>'Żaneta', 'table_name'=>technical_name,
  'variant'=>GameRoomTableVariant.payload(EltenGameRoom::GAME_REGISTRY.build('uno'), {'score_limit'=>500})
}
[
  [{}, "Żaneta zaprasza cię do stołu #{technical_name} (UNO, 500 punktów)."],
  [{'tournament_match'=>true}, 'Żaneta zaprasza cię na mecz turniejowy (UNO, 500 punktów).'],
  [{'tournament_match'=>true, 'continuation'=>true}, 'Żaneta zaprasza cię do wznowienia meczu turniejowego (UNO, 500 punktów).']
].each do |flags, expected|
  notice = Notice2.new(id: 900, app_uuid: uuid, sender: 'Żaneta', type: 'game_room.invitation',
    metadata: invitation_metadata.merge(flags))
  fields = EltenGameRoom.map_notification(notice).instance_variable_get(:@options)
  assert(fields[:body] == expected, "Invitation wording differs: #{fields}")
  assert(fields[:action] == :open_invitation && fields[:sound] == 'notice', 'Invitation action or sound changed')
end
%w[{} broken].each do |options|
  row = {'owner'=>'Bob','game'=>'uno','game_options'=>options}
  label = app.send(:table_join_label, WidgetSnapshot.new(table: row, members: ['Bob']))
  assert(!label.match?(/punkt|UNO|,\s*\z/), "Missing metadata guessed: #{label}")
end
puts 'PASS Polish widget, Join and both notification labels share short variants; missing metadata has no invented defaults'
