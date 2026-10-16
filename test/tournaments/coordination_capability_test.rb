# encoding: UTF-8
require_relative '../support/tournament_coordination_fixture'
F = TournamentCoordinationFixture
F.assert(defined?(GameRoomTournaments::CoordinationService), 'Brak fasady koordynacji')
port = Object.new
calls = []
port.define_singleton_method(:identity) { 'fixture:owner' }
port.define_singleton_method(:negotiate) { |**_| calls << :negotiate; {'status'=>'unsupported'} }
%i[reserve create_bind invite start].each do |name|
  port.define_singleton_method(name) { |**_| calls << name; raise 'Niedozwolony skutek' }
end
F.isolated do |dir|
  service = GameRoomTournaments::CoordinationService.new(port: port, trusted_identity: 'fixture:owner',
    directory: dir, registry: TournamentMatchFixture.registry, context: -> { F.context })
  result = service.request_match(request: F.request)
  F.assert(result[:state] == :coordination_unavailable, 'Brak capability musi odmówić')
  F.assert(calls == [:negotiate], 'Brak capability: zero skutków')
  F.assert(Dir.children(dir).empty?, 'Brak capability nie przygotowuje operacji')
end
puts 'PASS capability: coordination_unavailable, zero reserve/create/invite/start'
