# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
C=GameRoomTournaments::CoordinationContract
passed=[]
check=->(name,&block) do
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request);ctx=F.context
    factory=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx }) }
    block.call(request,port,ctx,factory,dir)
    passed << name
  end
end
C::REQUIRED.each_key do |key|
  [nil,1.0,2].each do |version|
    check.call("capability #{key} #{version.inspect}") do |r,p,_,s,_|
      p.capabilities[key]=version
      F.assert(s.call.request_match(request:r)[:state]==:coordination_unavailable,'Brak dokładnej capability')
      F.assert(!p.calls.include?(:reserve_before) && !p.calls.include?(:create_before),'Zero skutków')
    end
  end
end
%w[retention authorization max_bytes identity scope].each do |field|
  check.call("negocjacja #{field}") do |r,p,_,s,_|
    p.hook=->(event,v) { v[field]=nil if event==:negotiate }
    F.assert(s.call.request_match(request:r)[:state]==:coordination_unavailable,'Niepełna negocjacja')
    F.assert(!p.calls.include?(:reserve_before),'Zero reserve')
  end
end
[99,200,201].each do |time|
  check.call("okno #{time}") do |r,p,_,s,_|
    p.time=time
    F.assert(s.call.request_match(request:r)[:reason]==:outside_window,'[opens,closes)')
    F.assert(!p.calls.include?(:reserve_before),'Zero reserve poza oknem')
  end
end
check.call('opens włącznie') do |r,p,_,s,_|
  p.time=100
  F.assert(s.call.request_match(request:r)[:state]==:bound,'Dolna granica dozwolona')
end
%w[alice bob].each do |who|
  check.call("gotowość #{who}") do |r,p,_,s,_|
    p.ready[who]['state']='withdrawn'
    F.assert(s.call.request_match(request:r)[:reason]==:not_all_ready,'Cały skład ready')
    F.assert(!p.calls.include?(:reserve_before),'Zero reserve przy braku ready')
  end
end
%w[status seal_status request authorized_account server_time resource_revision ready shared].each do |field|
  check.call("snapshot brak #{field}") do |r,p,_,s,_|
    p.hook=->(event,v) { v[field]=nil if event==:snapshot }
    F.assert(s.call.request_match(request:r)[:binding].nil?,'Niepełny snapshot bez bindingu')
    F.assert(!p.calls.include?(:reserve_before),'Niepełny snapshot zero reserve')
  end
end
check.call('obserwowany kandydat') do |r,p,_,s,_|
  r['state']='observed_candidate'
  F.assert(s.call.request_match(request:r)[:state]==:blocked && p.calls.empty?,'Nie awansuj kandydata')
end
check.call('konkurencyjna operacja') do |r,p,_,s,_|
  p.competing='other-operation'
  F.assert(s.call.request_match(request:r)[:reason]==:competing_operation,'Globalna konkurencja od portu')
  F.assert(!p.calls.include?(:reserve_before),'Nie rezerwuj')
end
check.call('ownerstring nie jest uczestnikiem') do |r,_,ctx,s,dir|
  ctx['account']='mallory'
  port=TournamentCoordinationPort.new(r,account:'mallory')
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx })
  F.assert(service.request_match(request:r)[:state]==:blocked && !port.calls.include?(:reserve_before),'Obcy aktor bez delegacji')
end
check.call('jawna delegacja bez native takeover') do |r,_,ctx,s,dir|
  ctx['account']='delegate'
  port=TournamentCoordinationPort.new(r,account:'delegate')
  port.delegation={'account'=>'delegate','policy_ref'=>'approved-test-delegation'}
  service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx })
  F.assert(service.request_match(request:r)[:state]==:bound,'Port potwierdza delegację')
end
%w[account backend_identity runtime generation epoch cancelled grant_epoch].each do |field|
  check.call("kontekst brak #{field}") do |r,p,ctx,s,_|
    ctx.delete(field)
    F.assert(s.call.request_match(request:r)[:state]==:blocked && p.calls.empty?,'Niepełny kontekst przed I/O')
  end
  check.call("kontekst zmiana #{field}") do |r,p,ctx,s,_|
    p.hook=->(event,_) { ctx[field]=field=='cancelled' ? true : field.include?('epoch') ? 3 : 'changed' if event==:snapshot }
    F.assert(s.call.request_match(request:r)[:state]==:blocked && !p.calls.include?(:reserve_before),'Zmiana podczas I/O')
  end
end
%w[fencing revision holder_account coordinator_epoch ready_versions window expires_at].each do |field|
  check.call("stary grant #{field}") do |r,p,_,s,_|
    p.hook=->(event,_) do
      if event==:reserve_after
        p.grant[field]=case field
        when 'fencing' then 8
        when 'expires_at' then 150
        when 'ready_versions' then {'alice'=>'new','bob'=>'ready-1'}
        when 'window' then r['window'].merge('closes'=>151)
        else 'changed'
        end
      end
    end
    F.assert(s.call.request_match(request:r)[:state]==:blocked,'Zmiana grantu')
    F.assert(!p.calls.include?(:create_before),'Stary grant zero create')
  end
end
check.call('ready zmienia się po reserve') do |r,p,_,s,_|
  p.hook=->(event,_) { p.ready['bob']['revision']='ready-2' if event==:reserve_after }
  F.assert(s.call.request_match(request:r)[:state]==:blocked && !p.calls.include?(:create_before),'Nowe ready unieważnia grant')
end
check.call('okno kończy się po reserve') do |r,p,_,s,_|
  p.hook=->(event,_) { p.time=200 if event==:reserve_after }
  F.assert(s.call.request_match(request:r)[:reason]==:outside_window && !p.calls.include?(:create_before),'Nowy create po closes=0')
end
%w[scope operation_id request_digest operation receipt result].each do |field|
  check.call("readback mismatch #{field}") do |r,p,_,s,_|
    p.hook=->(event,v) do
      if event==:lookup && v && v['kind']=='create_bind'
        case field
        when 'scope' then v['scope']['tournament_id']='other'
        when 'operation' then v['operation']['request']['leg']=1.0
        when 'result' then v['result']['table_id']=42.0
        else v[field]='mismatch'
        end
      end
    end
    F.assert(s.call.request_match(request:r)[:state]==:blocked,'Exact readback odmówił')
    F.assert(p.calls.count(:create_before)==1,'Nie próbuj innego klucza')
  end
end
%w[pending conflict refused unsupported unknown absent_final].each do |state|
  check.call("create stan #{state}") do |r,p,_,s,_|
    p.hook=->(event,v) do
      if event==:create_after
        v.merge!('status'=>state,'reason'=>state,'receipt'=>nil,'result'=>nil,'resource_revision'=>nil)
        p.operations['create_bind']=p.copy(v)
      end
    end
    service=s.call
    first=service.request_match(request:r)
    F.assert(first[:state]==(state=='unsupported' ? :coordination_unavailable : state.to_sym),'Zachowaj jawny stan')
    p.hook=nil
    second=s.call.request_match(request:r)
    F.assert(second[:binding].nil? && p.calls.count(:create_before)==1,'Stan nie daje nowego create')
  end
end
%i[reserve_before reserve_after create_before create_stored create_after].each do |point|
  check.call("utrata #{point}") do |r,p,_,s,_|
    p.hook=->(event,_) { raise C::PortUnavailable,'Utrata odpowiedzi' if event==point }
    first=s.call.request_match(request:r)
    F.assert(first[:state]==:unknown,'Niepewność po mutacji')
    original=first[:operation_id];p.hook=nil
    second=s.call.reconcile(request:r)
    expected=[:create_stored,:create_after].include?(point) ? :bound : point==:reserve_after ? :reserved : :unknown
    F.assert(second[:state]==expected && second[:operation_id]==original,'Oryginalny klucz i właściwy readback')
    F.assert(p.calls.count(point)<=1,'Bez ponowienia')
  end
end
check.call('reentry ten sam i drugi obiekt') do |r,p,_,s,_|
  service=s.call;other=s.call;answers=[]
  p.hook=->(event,_) do
    if event==:reserve_before
      answers << service.request_match(request:r)
      answers << other.request_match(request:r)
    end
  end
  F.assert(service.request_match(request:r)[:state]==:bound,'Pełny pion właściciela')
  F.assert(answers.size==2 && answers.all? { |a| a[:reason]==:local_busy },'Reentry bez deadlocka i bez cudzej finalizacji')
  F.assert(p.calls.count(:reserve_before)==1,'Jedno prawo wysłania')
end
check.call('aktywny rescue wywołującego') do |r,p,ctx,s,_|
  service=s.call
  p.hook=->(event,_) { ctx['epoch']=3 if event==:snapshot }
  begin
    raise 'Dawny obsłużony wyjątek'
  rescue RuntimeError
    F.assert(service.request_match(request:r)[:state]==:blocked,'Kontrola po udanym I/O mimo odziedziczonego $!')
  end
end
puts JSON.generate({passed:passed.length,cases:passed})
