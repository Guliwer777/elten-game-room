# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja default/clock'); super(value, message); end
T = GameRoomTournaments
provider = T::LocalFixedTeamNativeProvider.new
transaction = provider.open(state: {'creates' => [], 'cores' => []}, owner: 'Ala')
transport = GameRoomTransport.new(transaction.program)
begin
  assert_equal(GameRoomClock, transport.instance_variable_get(:@live_store).instance_variable_get(:@clock))
  transport.start
  table = transport.create_room(name: 'Ordinary control', game: 'spades', owner: 'Ala',
    game_options: JSON.generate(TournamentFT2B1::REGISTRY.build('spades').normalize_options({'team_size' => 2})),
    private_table: true, capacity: 4, bot_count: 0)
  row = transport.room_snapshot(table['__id'], force: true, read_only: true)[:table]
  assert_equal(table['__live_session_id'], row['__live_session_id'])
  assert_equal('Ordinary control', row['name'])
  assert_equal(1, transaction.dump['creates'].size)
  snapshot = transaction.dump
  view = transaction.program.live_sessions.sessions.first
  require EltenTestHost.file('src/eapi/server_clock.rb')
  assert_equal(nil, EltenAPI::ServerClock.now)
  refused = false
  begin
    transport.start
  rescue GameRoomNetworkErrors::ClockUnavailable
    refused = true
  end
  assert(refused, 'Default ordinary przestał używać hostowego zegara')
  transaction.close
  blocked = false
  begin
    view.stack_push({'kind' => 'room_created', 'actor' => 'Ala'}, message_id: 'after-close')
  rescue T::CoordinationContract::Blocked => error
    blocked = error.code == :local_view_closed
  end
  assert(blocked, 'Zamknięty lokalny widok dopuścił zapis')
  assert_equal(false, snapshot['cores'].first['closed'], 'Zamknięto trwały pokój')
  puts 'PASS ordinary default create/read, niesynchronizowany host odmawia ordinary, lokalny close blokuje późną mutację bez zamykania pokoju'
ensure
  transaction.close
end
