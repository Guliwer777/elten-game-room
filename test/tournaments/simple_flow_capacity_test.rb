require_relative '../support/tournament_individual_ui'
include GameRoomTest::Assertions
I = TournamentIndividualUI
T = GameRoomTournaments
state = I.fixture(participant_limit: 2)
state[:now], state[:actor] = 150, 'Third'
gateway = T::TablesGateway.new(server_tables: state[:tables], user: -> { state[:actor] }, operation_error_classes: [T::LocalTestTables::Error])
service = T::PublicService.new(gateway: gateway, journal: state[:journal].call, registry: GameRoomGames::CATALOG,
  user: -> { state[:actor] }, backend_identity: state[:tables].backend_identity, clock: -> { state[:now] })
row = service.list['announcements'].first
begin
  service.join(tournament_id: row['__id'])
  raise 'Third player exceeded capacity'
rescue T::PublicService::Error => error
  assert_equal(:participant_limit_reached, error.code)
end
assert_equal(2, service.list['members'].size)
assert_equal([], state[:journal].call.list)
puts 'PASS participant capacity rejects excess join before preparing operation'
state[:program].finalize
state[:program].class.app_runtime.close
