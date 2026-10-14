# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
F.isolated do |dir|
  service=S.new(port:Object.new,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context })
  F.assert(service.request_match(request:F.request)[:state]==:coordination_unavailable,'Brak portu/capability odmawia, nie NoMethodError')
  F.assert(Dir.children(dir).empty?,'Brak portu nie tworzy dziennika')
end
F.isolated do |dir|
  request=F.request;port=TournamentCoordinationPort.new(request)
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context:nil)
  F.assert(service.request_match(request:request)[:state]==:blocked && port.calls.empty?,'Brak czytnika epoki odmawia przed I/O')
end
puts 'PASS brak portu/czytnika jest jawną odmową, bez skutków'
