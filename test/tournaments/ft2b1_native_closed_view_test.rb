# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
T = GameRoomTournaments
transaction = T::LocalFixedTeamNativeProvider.new.open(state: {'creates' => [], 'cores' => []}, owner: 'Ala')
transport = GameRoomTransport.new(transaction.program, **transaction.transport_options)
arguments = {name: 'FT2A', game: 'spades', owner: 'Ala', game_options: '{}', private_table: true, capacity: 4, bot_count: 0}
begin
  table = transport.create_room(**arguments)
  before = transaction.dump
  transport.close_local_view
  failure = nil
  begin
    transport.create_room(**arguments)
  rescue IOError => error
    failure = error.message
  end
  assert_equal('Local transaction view is closed', failure, 'Zamknięty Transport ponownie tworzy pokój')
  assert_equal(before, transaction.dump, 'Późny zapis zmienił core')
  assert_equal(false, before['cores'].first['closed'])
  assert_equal(table['__live_session_id'], before['cores'].first['id'])
  transport.close_local_view
  puts 'PASS zamknięty Transport odmawia ponownego create bez zmiany core'
ensure
  transaction.close
end
