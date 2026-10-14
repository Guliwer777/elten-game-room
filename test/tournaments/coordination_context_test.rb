# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
locks=[]
File.singleton_class.prepend(Module.new do
  define_method(:open) do |path,*args,**kwargs,&block|
    value=super(path,*args,**kwargs,&block)
    locks << value if path.to_s.end_with?('.lock') && value.is_a?(File)
    value
  end
end)
F.isolated do |dir|
  request=F.request; port=TournamentCoordinationPort.new(request); context=F.context
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { context })
  port.hook=->(event,_) { context['epoch']+=2 if event==:create_stored }
  result=service.request_match(request:request)
  F.assert(result[:state]==:blocked,'A→B→A odcina wynik')
  F.assert(locks.all?(&:closed?),'Po zmianie epoki zwolnij lokalne flock, bez ponownego prawa skutku')
  F.assert(port.calls.count(:create_before)==1,'Jeden create mimo anulowania po store')
  port.hook=nil
  fresh=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { context })
  read=fresh.reconcile(request:request)
  F.assert(read[:binding].is_a?(GameRoomTournaments::MatchBinding),'Nowy runtime odczytuje ten sam binding')
  F.assert(port.calls.count(:create_before)==1,'Reconcile bez ponowienia')
end
puts 'PASS ABA i cleanup rzeczywistego flock po odcięciu kontekstu'
