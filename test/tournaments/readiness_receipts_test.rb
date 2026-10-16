# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
passed=[]
%w[pending unknown refused conflict unsupported].each do |status|
  F.isolated do |dir|
    p=F::Port.new; source=F::Context.new
    p.hook=->(event,value) do
      if event==:store_after
        value.replace(p.receipt(value['operation'],status))
        p.operations[value['operation']['operation_id']]=F.copy(value)
      end
    end
    answer=F.service(dir,p,source).declare(request:F.request)
    F.assert(answer[:state]==status.to_sym,"Jawny readback #{status}")
    p.hook=nil
    again=F.service(dir,p,source).declare(request:F.request)
    F.assert(again[:state]==status.to_sym && again[:operation_id]==answer[:operation_id],"#{status}: ten sam readback")
    F.assert(p.calls.count(:store_before)==1,'Niepewność/odmowa nie staje się write')
    passed << status
  end
end
mutations={
  'account'=>->(r) { r['result']['account']='bob' },
  'scope'=>->(r) { r['operation']['request']['scope']['tournament_id']='obcy' },
  'match'=>->(r) { r['operation']['request']['match_ref']['match_id']='obcy' },
  'operation_id'=>->(r) { r['operation']['operation_id']='obcy' },
  'digest'=>->(r) { r['request_digest']='0'*64 },
  'expected_float'=>->(r) { r['operation']['request']['expected_ready_revision']=0.0 },
  'revision_float'=>->(r) { r['result']['ready_revision']=1.0 },
  'state'=>->(r) { r['result']['state']='withdrawn' },
  'grant_duplicate'=>->(r) { r['result']['invalidated_grants']=['g','g'] },
  'grant_changed'=>->(r) { r['result']['invalidated_grants']=['inny'] },
  'time_float'=>->(r) { r['result']['server_time']=101.0 },
  'revision_stale'=>->(r) { r['result']['ready_revision']=0 }
}
mutations.each do |name,mutate|
  F.isolated do |dir|
    p=F::Port.new; source=F::Context.new
    p.hook=->(event,value) { mutate.call(value) if event==:lookup }
    answer=F.service(dir,p,source).declare(request:F.request)
    F.assert(answer[:state]==:blocked && answer[:receipt].nil?,"Wadliwy receipt #{name}")
    p.hook=nil
    result=F.service(dir,p,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:answer[:operation_id])
    F.assert(result[:state]==:confirmed && p.calls.count(:store_before)==1,'Późniejsze uzgodnienie, zero resend')
    passed << name
  end
end
F.isolated do |dir|
  p=F::Port.new; source=F::Context.new
  F.assert(C.const_defined?(:KnownRefused,false),'Jawny typ odmowy przed przyjęciem, odrębny od uncertainty')
  p.hook=->(event,op) do
    if event==:store_before
      p.operations[op['operation_id']]=p.receipt(op,'refused')
      raise C::KnownRefused,'Odmowa przed przyjęciem przez testowy port'
    end
  end
  first=F.service(dir,p,source).declare(request:F.request)
  F.assert(first[:state]==:refused && first[:reason]==:known_refused,'KnownRefused nie jest unknown')
  p.hook=nil
  answer=F.service(dir,p,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:first[:operation_id])
  F.assert(answer[:state]==:refused && p.calls.count(:store_before)==1,'Odmowa rozstrzygnięta wyłącznie oryginalnym lookup')
  passed << 'KnownRefused'
end
puts JSON.generate({passed:passed.size,cases:passed})
