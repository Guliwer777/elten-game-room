# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
mutations={
  'nil potwierdzonego dowodu'=>->(doc) { doc['operations'].last['evidence']=nil },
  'tablica dowodu'=>->(doc) { doc['operations'].last['evidence']=[] },
  'digest'=>->(doc) { doc['operations'][0]['operation']['request_digest']='x'*64 },
  'typ leg'=>->(doc) { doc['operations'][0]['operation']['request']['leg']=1.0 },
  'obce konto'=>->(doc) { doc['account']='bob' },
  'obcy backend'=>->(doc) { doc['scope']['backend_identity']='other' },
  'nieznany stan'=>->(doc) { doc['operations'][0]['status']='reset' },
  'duplikat operacji'=>->(doc) { doc['operations'] << doc['operations'][0] },
  'nieznane pole sekretu'=>->(doc) { doc['operations'][0]['token']='test-niedozwolone-pole' }
}
passed=[]
mutations.each do |name,change|
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request)
    factory=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context }) }
    F.assert(factory.call.request_match(request:request)[:state]==:bound,'Fixture poprawnego całego dokumentu')
    path=Dir.glob(File.join(dir,'coordination-v1','*.json')).first
    doc=JSON.parse(File.binread(path));change.call(doc);bytes=JSON.generate(doc);File.binwrite(path,bytes)
    rejected=false
    begin
      factory.call.reconcile(request:request)
    rescue GameRoomTournaments::CoordinationJournal::Corrupt
      rejected=true
    end
    F.assert(rejected,"Corrupt, nie unknown/naprawa: #{name}")
    F.assert(File.binread(path)==bytes && port.calls.count(:create_before)==1,'Uszkodzenie bez zapisu i skutków')
    passed << name
  end
end
%w[duplicate escaped nested utf8 bytes depth].each do |name|
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request)
    factory=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context }) }
    F.assert(factory.call.request_match(request:request)[:state]==:bound,'Poprawny dokument przed mutacją')
    path=Dir.glob(File.join(dir,'coordination-v1','*.json')).first;bytes=File.binread(path)
    bytes=case name
    when 'duplicate' then bytes.sub('"schema_version":1','"schema_version":1,"schema_version":1')
    when 'escaped' then bytes.sub('"schema_version":1','"schema_version":1,"\\u0073chema_version":1')
    when 'nested' then bytes.sub('"leg":1','"leg":1,"leg":1')
    when 'utf8' then bytes.sub('fixture:owner',"\xff".b)
    when 'bytes' then ' '*8_388_609
    when 'depth' then '['*30+'0'+']'*30
    end
    File.binwrite(path,bytes);rejected=false
    begin
      factory.call.reconcile(request:request)
    rescue GameRoomTournaments::CoordinationJournal::Corrupt
      rejected=true
    end
    F.assert(rejected && File.binread(path)==bytes,"Bajty #{name} odrzucone bez naprawy")
    passed << name
  end
end
puts JSON.generate({passed:passed.length,cases:passed})
