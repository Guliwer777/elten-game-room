# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new
  broken=false
  reader=-> { throw :ucieczka,:nie_wolno if broken; source.call }
  service=GameRoomTournaments::ReadinessService.new(port:port,trusted_identity:'fixture:k03',directory:dir,context:reader)
  primary=NoMethodError.new('Pierwotny błąd'); primary.set_backtrace(['pierwotny:2'])
  port.hook=->(event,_) do
    if event==:store_after
      broken=true
      raise primary,cause:nil
    end
  end
  begin
    catch(:ucieczka) { service.declare(request:F.request) }
    F.assert(false,'Throw nie może połknąć primary')
  rescue NoMethodError => error
    F.assert(error.equal?(primary) && error.cause.nil? && error.backtrace==['pierwotny:2'],'Primary bez dopisywania cause')
  end
  port.hook=nil
  result=F.service(dir,port,source).declare(request:F.request)
  F.assert(result[:state]==:confirmed && port.calls.count(:store_before)==1,'Cleanup zwolnił uchwyt także po throw z czytnika')
end
puts JSON.generate({passed:1,opis:'Nielokalne wyjście callbacka nie zabiera primary ani uchwytu'})
