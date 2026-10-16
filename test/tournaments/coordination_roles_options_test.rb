# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
passed=[]
['uno','axel_pong'].each do |game|
  F.isolated do |dir|
    request=F.request(game:game)
    model=TournamentMatchFixture.registry.build(game)
    if game=='uno'
      request['options']['draw_responses']=!request['options']['draw_responses']
    else
      request['options']=model.normalize_options(request['options'].merge('target'=>'unlimited'))
    end
    request['players'][0]['game_role']='jawnie-przyjęta-rola-A'
    request['players'][1]['game_role']='jawnie-przyjęta-rola-B'
    request['observers']=[{'username'=>'Observer','account'=>'observer','role'=>'observer','seat'=>nil,'team'=>nil,'game_role'=>nil}]
    port=TournamentCoordinationPort.new(request)
    service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context })
    result=service.request_match(request:request)
    F.assert(result[:state]==:bound,"Rzeczywiste opcje #{game}: #{result.inspect}")
    F.assert(result[:binding].to_h['options'].eql?(request['options']),'Pełne nie-domyślne typed options')
    F.assert(result[:binding].to_h['observers'].eql?(request['observers']),'Obserwator nie jest graczem/ready')
    port.time=201
    F.assert(service.reconcile(request:request)[:state]==:bound,'Odczyt rozpoczętego skutku po zamknięciu okna bez nowego create')
    F.assert(port.calls.count(:create_before)==1,'Koniec okna nie zeruje operacji')
    passed << game
  end
end
F.isolated do |dir|
  request=F.request(names:["\u0130"*64,'Bob'])
  port=TournamentCoordinationPort.new(request,account:request['players'][0]['account'])
  ctx=F.context(account:request['players'][0]['account'])
  result=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { ctx }).request_match(request:request)
  F.assert(result[:state]==:bound,'Raw nazwa i rozszerzony canonical bez obcinania')
  passed << 'Unicode raw/canonical'
end
puts JSON.generate({passed:passed.length,cases:passed})
