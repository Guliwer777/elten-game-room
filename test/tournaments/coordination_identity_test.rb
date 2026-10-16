# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
F.isolated do |dir|
  request=F.request;port=TournamentCoordinationPort.new(request);identity='fixture:owner'
  port.define_singleton_method(:identity) { identity }
  port.hook=->(event,_) { identity='fixture:other' if event==:snapshot }
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context })
  answer=service.request_match(request:request)
  F.assert(answer[:state]==:blocked && !port.calls.include?(:reserve_before),'Zmiana identity portu podczas I/O odcina reserve')
end
puts 'PASS tożsamość zaufanego portu sprawdzana także po I/O'
