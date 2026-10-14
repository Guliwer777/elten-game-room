# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
passed=[]
%i[store_before store_after].each do |point|
  F.isolated do |dir|
    port=F::Port.new; source=F::Context.new; service=F.service(dir,port,source)
    F.assert(service.respond_to?(:reconcile), 'Brak odczytu dokładnej pierwotnej operacji po niepewności')
    port.hook=->(event,_) { raise C::PortUnavailable, 'Utrata odpowiedzi' if event==point }
    first=service.declare(request:F.request)
    F.assert(first[:state]==:unknown && first[:operation_id], 'Niepewna próba ma oryginalny UUID')
    port.hook=nil
    other=F.service(dir,port,source).declare(request:F.request('withdrawn',1))
    F.assert(other[:reason]==:unresolved_operation, 'Nowy sprzeczny zamiar zablokowany')
    port.view['policy']={'status'=>'unknown','ref'=>nil,'allows'=>[]}
    port.view['phase']='started'
    port.capabilities=C::READ.dup
    restored=F.service(dir,port,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:first[:operation_id])
    F.assert(restored[:state]==(point==:store_after ? :confirmed : :unknown), 'Odczyt nie wymaga nowej polityki, okna lub grantu')
    F.assert(restored[:operation_id]==first[:operation_id], 'Dokładnie pierwotny UUID')
    F.assert(port.calls.count(:store_before)==1, 'Nigdy resend')
    passed << point
  end
end
puts JSON.generate({passed:passed.size,cases:passed})
