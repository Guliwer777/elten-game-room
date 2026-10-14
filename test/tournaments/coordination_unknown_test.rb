# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
C=GameRoomTournaments::CoordinationContract
F.isolated do |dir|
  p=F.request; port=TournamentCoordinationPort.new(p)
  new_service=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context }) }
  port.hook=->(event,_) { raise C::PortUnavailable,'Utrata przed store rezerwacji' if event==:reserve_before }
  first=new_service.call.request_match(request:p)
  F.assert(first[:state]==:unknown,'Niepewna rezerwacja')
  port.hook=nil
  second=new_service.call.reconcile(request:p)
  F.assert(second[:state]==:unknown,"Brak readback nie jest odmową ani zgodą na retry: #{second.inspect}")
  F.assert(first[:operation_id] && first[:operation_id]==second[:operation_id],'Zachowany klucz po utracie')
  F.assert(port.calls.count(:reserve_before)==1 && port.calls.count(:create_before)==0,'Bez nowego skutku')
end
puts 'PASS nieznany readback zachowuje oryginalny operation_id'
