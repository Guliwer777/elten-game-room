# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
C=GameRoomTournaments::CoordinationContract
class CoordinationProgramError < StandardError; end
locks=[]
File.singleton_class.prepend(Module.new do
  define_method(:open) do |path,*args,**kwargs,&block|
    value=super(path,*args,**kwargs,&block)
    locks << value if path.to_s.end_with?('.lock') && value.is_a?(File)
    value
  end
end)
F.isolated do |dir|
  request=F.request;port=TournamentCoordinationPort.new(request);ctx=F.context
  primary=CoordinationProgramError.new('Błąd programu po zdalnym store')
  cause=ArgumentError.new('Bezpośrednia przyczyna')
  original_backtrace=['synthetic-original:17']
  primary.set_backtrace(original_backtrace)
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx })
  port.hook=->(event,_) do
    if event==:create_stored
      ctx['epoch']+=2
      raise primary,cause:cause
    end
  end
  begin
    service.request_match(request:request)
    raise 'Zamaskowany ProgramError'
  rescue CoordinationProgramError => caught
    F.assert(caught.equal?(primary) && caught.cause.equal?(cause) && caught.backtrace==original_backtrace,'Obiekt/typ/direct cause/backtrace')
  end
  F.assert(service.diagnostics.any?,'Diagnoza wtórnej zmiany kontekstu')
  port.hook=nil
  fresh=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx })
  result=fresh.reconcile(request:request)
  F.assert(result[:state]==:bound && port.calls.count(:create_before)==1,'ProgramError nie zeruje attempted')
end
# Błąd wtórnego czytnika kontekstu też nie może przykryć błędu mutacji.
F.isolated do |dir|
  request=F.request;port=TournamentCoordinationPort.new(request);fail_context=false
  primary=CoordinationProgramError.new('Pierwotny program');cause=ArgumentError.new('Przyczyna')
  primary.set_backtrace(['primary:1'])
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,
    context: -> { raise 'Wtórny czytnik' if fail_context; F.context })
  port.hook=->(event,_) { if event==:create_stored; fail_context=true;raise primary,cause:cause;end }
  begin
    service.request_match(request:request)
  rescue CoordinationProgramError => caught
    F.assert(caught.equal?(primary) && caught.cause.equal?(cause),'Drugi wyjątek nie maskuje primary')
  end
  F.assert(locks.all?(&:closed?),'Błąd czytnika nie może zatrzymać zwolnienia lokalnego flock')
end
puts 'PASS ProgramError ten sam obiekt, cause i backtrace; uncertainty pozostaje attempted'
