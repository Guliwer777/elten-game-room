# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
passed=[]
[:account,:backend,:runtime,:cancel].each do |kind|
  [:before,:negotiate,:snapshot,:store_before,:store_after,:lookup].each do |point|
    F.isolated do |dir|
      p=F::Port.new; source=F::Context.new; service=F.service(dir,p,source)
      service.current(scope:F.scope,match_ref:F.match_ref)
      change=-> { source.emit(kind,{account:'bob',backend:'fixture:other',runtime:'runtime-B',cancel:true}.fetch(kind)) }
      if point==:before
        change.call
      else
        p.hook=->(event,_) { change.call if event==point }
      end
      answer=service.declare(request:F.request)
      F.assert(answer[:state]==:blocked, "#{kind}/#{point}: stary kontekst nie potwierdza wyniku")
      expected=[:store_before,:store_after,:lookup].include?(point) ? 1 : 0
      F.assert(p.calls.count(:store_before)==expected, "#{kind}/#{point}: skutki tylko przed utratą kontekstu")
      F.assert(service.declare(request:F.request)[:state]==:blocked,'Zmiana zatrzaśnięta')
      passed << "#{kind}/#{point}"
    end
  end
end
[:account,:backend].each do |kind|
  F.isolated do |dir|
    p=F::Port.new; source=F::Context.new; service=F.service(dir,p,source)
    p.hook=->(event,_) do
      next unless event==:snapshot
      source.emit(kind,kind==:account ? 'bob' : 'fixture:other')
      source.emit(kind,kind==:account ? 'alice' : 'fixture:k03')
    end
    F.assert(service.declare(request:F.request)[:state]==:blocked,'Emitowane ABA odrzuca wynik')
    F.assert(source.events.size==2 && p.calls.count(:store_before)==0,'Oba zdarzenia źródła, zero skutków')
    passed << "ABA #{kind}"
  end
end
[NoMethodError,ArgumentError].each do |klass|
  F.isolated do |dir|
    p=F::Port.new; source=F::Context.new; service=F.service(dir,p,source)
    primary=klass.new('Pierwotny błąd programu'); primary.set_backtrace(['test-pierwotny:7'])
    cause=RuntimeError.new('Pierwotna przyczyna')
    p.hook=->(event,_) do
      if event==:store_after
        source.emit(:cancel,true)
        raise primary, cause:cause
      end
    end
    begin
      service.declare(request:F.request)
      F.assert(false,'Błąd programu nie może być unknown')
    rescue klass => error
      F.assert(error.equal?(primary) && error.cause.equal?(cause) && error.backtrace==['test-pierwotny:7'],'Tożsamość primary/cause/backtrace')
    end
    snapshot=service.diagnostics
    F.assert(snapshot.frozen? && snapshot.any? { |d| d['attempt_id'] && d['class'] },'Odłączona przypisana diagnostyka')
    old=F.copy(snapshot)
    service.current(scope:F.scope,match_ref:F.match_ref)
    F.assert(snapshot.eql?(old),'Historia wcześniejszej próby niezmienna')
    passed << klass.name
  end
end
F.isolated do |dir|
  p=F::Port.new; source=F::Context.new; service=F.service(dir,p,source)
  begin
    raise 'Dawny obsłużony wyjątek'
  rescue RuntimeError
    p.hook=->(event,_) { source.emit(:cancel,true) if event==:snapshot }
    F.assert(service.declare(request:F.request)[:state]==:blocked,'Ambient $! nie pomija guardu po udanym I/O')
  end
  passed << 'Ambient rescue'
end
F.isolated do |dir|
  p=F::Port.new; service=F.service(dir,p,F::Context.new)
  first=service.declare(request:F.request)
  current=service.current(scope:F.scope,match_ref:F.match_ref)
  F.assert(first[:operation_id] && current[:operation_id].nil?,'Bieżący odczyt nie przypisuje starej operacji nowej próbie')
  passed << 'Rozłączność prób'
end
puts JSON.generate({passed:passed.size,cases:passed})
