# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
passed=[]; failures=[]
check=->(name,change,reason) do
  F.isolated do |dir|
    port=F::Port.new; source=F::Context.new; request=F.request
    change.call(port,source,request)
    result=F.service(dir,port,source).declare(request:request)
    F.assert(result[:reason]==reason, "#{name}: właściwa odmowa, otrzymano #{result.inspect}")
    F.assert(port.calls.count(:store_before)==0 && Dir.glob(File.join(dir,'**','*.intent')).empty?, "#{name}: zero claim i skutków")
    passed << name
  rescue StandardError => e
    failures << [name,e.class.name,e.message]
  end
end
check.call('Nieustalone później',->(_,_,r) { r['availability']='later' },:later_unsupported)
[0.0,'0',nil,-1].each { |v| check.call("Rewizja #{v.inspect}",->(_,_,r) { r['expected_ready_revision']=v },:invalid_revision) }
check.call('Stara rewizja',->(p,_,_) { p.view['current']['ready_revision']=2 },:stale_revision)
check.call('Cudzy autor DTO',->(_,_,r) { r['account']='bob' },:invalid_fields)
check.call('Obcy organizator',->(p,s,_) { s.emit(:account,'organizator'); p.view['account']='organizator' },:not_participant)
check.call('Bot',->(p,_,_) { p.view['accepted_match']['members'][0]['kind']='bot' },:not_participant)
check.call('Obserwator',->(p,_,_) { p.view['accepted_match']['members'][0]['role']='observer' },:not_participant)
check.call('Kandydat',->(p,_,_) { p.view['accepted_match']['status']='unknown' },:unconfirmed_plan)
check.call('Niepełny skład',->(p,_,_) { p.view['accepted_match']['full_roster']=false },:unconfirmed_plan)
check.call('Role NIEUSTALONE',->(p,_,_) { p.view['accepted_match']['roles_status']='unassigned' },:unconfirmed_plan)
check.call('Powtórzony gracz',->(p,_,_) { p.view['accepted_match']['members'] << F.copy(p.view['accepted_match']['members'][0]) },:duplicate_member)
%w[ready withdrawn].each do |state|
  check.call("#{state} nieznana polityka",->(p,_,r) { r['availability']=state; p.view['policy']['status']='unknown' },:unconfirmed_policy)
  check.call("#{state} inna polityka",->(_,_,r) { r['availability']=state; r['policy_ref']='inna' },:unconfirmed_policy)
end
C::WRITE.each_key do |cap|
  [nil,1.0].each { |v| check.call("Gwarancja #{cap}:#{v.inspect}",->(p,_,_) { p.capabilities[cap]=v },:unsupported) }
end
check.call('Budżet portu',->(p,_,_) { p.hook=->(event,value) { value['max_bytes']=8 if event==:negotiate } },:payload_too_large)
check.call('Obcy zakres snapshotu',->(p,_,_) { p.view['scope']['tournament_id']='cudzy' },:snapshot_mismatch)
check.call('Obcy mecz snapshotu',->(p,_,_) { p.view['match_ref']['leg']=1.0 },:snapshot_mismatch)
check.call('Obcy autor snapshotu',->(p,_,_) { p.view['account']='bob' },:snapshot_mismatch)
check.call('Już started',->(p,_,_) { p.view['phase']='started' },:already_started)
%w[pending unknown refused conflict unsupported].each do |status|
  check.call("Jawny snapshot #{status}",->(p,_,_) { p.view['status']=status },status.to_sym)
end
F.isolated do |dir|
  [nil,{}].each do |context|
    p=F::Port.new
    s=GameRoomTournaments::ReadinessService.new(port:p,trusted_identity:'fixture:k03',directory:dir,context:context)
    F.assert(s.declare(request:F.request)[:reason]==:incomplete_context,'Brak zaufanego czytnika')
    F.assert(p.calls.empty?,'Brak port I/O przy braku kontekstu')
  end
  s=GameRoomTournaments::ReadinessService.new(port:nil,trusted_identity:'fixture:k03',directory:dir,context:F::Context.new.method(:call))
  F.assert(s.declare(request:F.request)[:reason]==:missing_port,'Brak portu jawny')
  passed << 'Brak źródeł'
end
puts JSON.generate({passed:passed.size,cases:passed,failures:failures})
F.assert(failures.empty?, 'Wszystkie odmowy mają jawne rozróżnione wyniki')
