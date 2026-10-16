# encoding: UTF-8
require_relative '../support/tournament_local_readiness'
include TournamentLocalReadinessSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
C=T::ReadinessContract
sandbox do |ctx|
  f=prepared(ctx)
  assert(f[:backend].respond_to?(:gate_state),'Brak trwałego lokalnego unieważnienia gate')
  assert_equal({'open'=>false,'revision'=>0,'grants'=>[]},f[:backend].gate_state(**f[:target]))
  ready=f[:service].declare(request:f[:request])
  assert_equal({'open'=>false,'revision'=>1,'grants'=>[]},f[:backend].gate_state(**f[:target]))
  operation=ready[:receipt]['operation']
  assert_equal(ready[:receipt],f[:backend].store(operation:operation))
  assert_equal(1,f[:backend].gate_state(**f[:target])['revision'])
  stale=C.operation(f[:request],'alicja',operation['accepted_match'],SecureRandom.uuid)
  assert_equal('conflict',f[:backend].store(operation:stale)['status'])
  assert_equal(1,f[:backend].gate_state(**f[:target])['revision'])
  badscope=f[:target][:scope].merge('tournament_id'=>'obcy')
  assert_raises(C::Blocked) { f[:backend].snapshot(scope:badscope,match_ref:f[:target][:match_ref]) }
  badaccepted=Marshal.load(Marshal.dump(operation['accepted_match']))
  badaccepted['plan_digest']='0'*64
  wrong=C.operation(f[:request],'alicja',badaccepted,SecureRandom.uuid)
  assert_raises(C::Blocked) { f[:backend].store(operation:wrong) }
  bob=T::LocalReadinessBackend.new(directory:File.join(ctx.directory,'k03'),actor:'Bob',source:f[:source])
  assert_raises(C::Blocked) { bob.lookup(operation:operation) }
  assert_equal('unknown',bob.snapshot(**f[:target])['current']['state'])
  assert_equal('confirmed',bob.store(operation:C.operation(f[:request],'bob',operation['accepted_match'],SecureRandom.uuid))['status'])
  assert_equal(2,f[:backend].gate_state(**f[:target])['revision'])
  withdrawn=f[:service].declare(request:f[:request].merge('availability'=>'withdrawn','expected_ready_revision'=>1))
  assert_equal(:confirmed,withdrawn[:state])
  assert_equal(3,f[:backend].gate_state(**f[:target])['revision'])
  assert_equal('ready',f[:backend].lookup(operation:operation)['result']['state'])
  path=File.join(ctx.directory,'k03','sandbox-k03.json')
  bytes=File.binread(path)
  [bytes.sub('"version":1','"version":1,"version":1'),bytes.sub('"version":1','"vers\\u0069on":1,"version":1'),bytes[0...-1],'{', 'null'].each do |corrupt|
    File.binwrite(path,corrupt)
    assert_raises(C::Blocked) { f[:backend].plans }
    assert_equal(corrupt,File.binread(path))
  end
  File.binwrite(path,bytes)
  document=JSON.parse(bytes)
  document['plans'].first['candidate']['unexpected']=true
  data=document['plans'].first['candidate'].reject { |key,_value| key=='observed_at' }
  document['plans'].first['source_digest']=Digest::SHA256.hexdigest(JSON.generate(data))
  File.binwrite(path,JSON.generate(document))
  assert_raises(C::Blocked) { f[:backend].plans }
  File.binwrite(path,bytes)
  mutations=[->(doc) {doc['receipts']=[nil]}, ->(doc) {doc['receipts']=[[]]},
    ->(doc) {doc['plans']=[nil]}, ->(doc) {doc['plans'].first['candidate']['windows']=[{}]},
    ->(doc) {doc['plans'].first['candidate']['matches'].first['leg']=3},
    ->(doc) do
      row=doc['receipts'].find { |item|item['status']=='conflict' }
      previous=row['operation']
      row['operation']=C.operation(previous['request'].merge('expected_ready_revision'=>1),'alicja',previous['accepted_match'],previous['operation_id'])
      row['request_digest']=row['operation']['request_digest']
      C.response!(row,row['operation'])
    end]
  mutations.each do |mutate|
    doc=JSON.parse(bytes)
    mutate.call(doc)
    candidate=doc['plans'].first && doc['plans'].first['candidate']
    if candidate
      doc['plans'].first['source_digest']=Digest::SHA256.hexdigest(JSON.generate(candidate.reject { |key,_value|key=='observed_at' }))
    end
    malformed=JSON.generate(doc)
    File.binwrite(path,malformed)
    assert_raises(C::Blocked) {f[:backend].plans}
    assert_equal(malformed,File.binread(path))
  end
  File.binwrite(path,bytes)
end
puts 'PASS CAS/dedup, prawdziwa rewizja zamkniętego gate, izolacja aktora/scope/kotwicy i odmowa korupcji'
