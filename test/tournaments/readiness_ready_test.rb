# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new; service=F.service(dir,port,source)
  F.assert(service.respond_to?(:declare), 'Brak trwałej własnej deklaracji ready')
  durable=nil
  port.hook=->(event,op) do
    next unless event==:store_before
    documents=Dir.glob(File.join(dir,'readiness-v1','**','state.json')).map { |path| JSON.parse(File.read(path)) }
    durable=documents.flat_map { |d| d['records'] }.find { |r| r['operation'].eql?(op) }
    F.assert(durable && durable['status']=='attempted', 'Trwałe attempted przed port.store')
  end
  answer=service.declare(request:F.request)
  F.assert(answer[:state]==:confirmed, 'Dokładnie potwierdzony zapis ready')
  F.assert(answer[:receipt]['result']['state']=='ready', 'Potwierdzona własna gotowość')
  F.assert(answer[:receipt]['result']['account']=='alice', 'Autor nie pochodzi z żądania')
  F.assert(answer[:operation_id]==durable['operation']['operation_id'], 'Ten sam UUID dysk/store/lookup')
  F.assert(port.calls.count(:store_before)==1 && port.calls.count(:lookup)==1, 'Jeden skutek i jeden dokładny readback')
  again=F.service(dir,port,source).declare(request:F.request)
  F.assert(again[:state]==:confirmed && again[:operation_id]==answer[:operation_id], 'Duplikat zamiaru czyta pierwotną operację')
  F.assert(port.calls.count(:store_before)==1, 'Bez resend potwierdzonego zamiaru')
end
puts JSON.generate({passed:1,opis:'Trwała własna deklaracja ready'})
