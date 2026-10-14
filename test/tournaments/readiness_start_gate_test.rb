# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
passed=[]
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new; service=F.service(dir,port,source)
  F.assert(service.declare(request:F.request)[:state]==:confirmed,'Skład gotowy w symulatorze')
  answer=service.declare(request:F.request('withdrawn',1))
  F.assert(answer[:state]==:confirmed && answer[:receipt]['result']['invalidated_grants']==['grant-test'],'Wycofanie unieważnia grant w symulacji')
  allowed=port.view['current']['state']=='ready'
  port.view['phase']='started' if allowed
  F.assert(!allowed && port.view['phase']=='not_started','Kolejność withdrawal→start: start nie nastąpił')
  passed << 'symulacja withdrawn przed start'
end
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new; service=F.service(dir,port,source)
  service.declare(request:F.request)
  port.hook=->(event,_) { port.view['phase']='started' if event==:store_before }
  answer=service.declare(request:F.request('withdrawn',1))
  F.assert(answer[:state]==:conflict && port.view['current']['state']=='ready' && port.view['phase']=='started','Kolejność start→withdrawal: nie cofamy partii')
  passed << 'symulacja start przed withdrawn'
end
[2,3,4,7].each do |count|
  F.isolated do |dir|
    p=F::Port.new
    p.view['accepted_match']['members']=(['alice']+(1...count).map { |n| "gracz#{n}" }).map { |a| {'account'=>a,'kind'=>'human','role'=>'player'} }
    answer=F.service(dir,p,F::Context.new).declare(request:F.request)
    F.assert(answer[:state]==:confirmed && answer[:receipt]['operation']['accepted_match']['members'].size==count,'Pełne różne składy, nie para z większego meczu')
    passed << "skład #{count}"
  end
end
puts JSON.generate({passed:passed.size,cases:passed,ograniczenie:'Wyłącznie proponowany testowy port, nie dowód atomowości serwera sieciowego'})
