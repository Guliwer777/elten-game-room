require_relative "../support/ui"
require_relative "../support/native_live_sessions"
class Program
  def self.server_app(**_options); end
end
require_relative "../../__app"
$game_room_test_user = 'Alice'
marker={'publication_ref'=>{'author'=>'Alice','publication_key'=>'f'*64},'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>2}
[nil,marker].each do |tournament|
EltenGameRoom::GAME_REGISTRY.ids.each do |id|
  game = EltenGameRoom::GAME_REGISTRY.build(id)
  broker = NativeLiveSessionsBroker.new
  transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Alice')))
  options = JSON.generate(game.default_options)
  table = transport.create_room(name:'Ż'*60,game:id,owner:'Alice',game_options:options,capacity:8,tournament_match:tournament)
  store = transport.instance_variable_get(:@live_store)
  metadata = broker.cores.values.first.discovery_metadata.merge('control_anchor'=>{'seq'=>9999999,'digest'=>'f'*64})
  compact = store.send(:compact_discovery,metadata)
  assert(JSON.generate(compact).bytesize <= 1024, "#{id}: native metadata limit exceeded")
  assert(store.send(:discovery_options,compact)==options, "#{id}: settings changed in discovery")
  assert_equal(tournament, GameRoomTournamentMarker.unpack(compact.fetch('match_ref'))) if tournament
end
end
puts 'All game profiles fit native discovery with a control anchor and Unicode table name: OK'
