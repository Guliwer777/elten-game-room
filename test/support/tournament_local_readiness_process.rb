# encoding: UTF-8
require_relative 'tournament_local_readiness'
require_relative '../../lib/tournaments/readiness_history'
include TournamentLocalReadinessSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
mode,directory,job_name=ARGV
ctx=TournamentLocalWorkspaceSupport::Context.new(directory)
case mode
when 'seed', 'cold-a'
  f=prepared(ctx)
  input={'target'=>f[:target].transform_keys(&:to_s),'request'=>f[:request],'context'=>f[:context]}
  if mode=='cold-a'
    ready=f[:service].declare(request:f[:request])
    assert_equal(:confirmed,ready[:state])
    input['ready_id']=ready[:operation_id]
    original=File.method(:rename)
    File.define_singleton_method(:rename) do |from,to|
      result=original.call(from,to)
      raise IOError,'Awaria po rzeczywistym rename' if to.end_with?('sandbox-k03.json')
      result
    end
    begin
      withdrawn=f[:service].declare(request:f[:request].merge('availability'=>'withdrawn','expected_ready_revision'=>1))
    ensure
      File.define_singleton_method(:rename,original)
    end
    assert_equal(:unknown,withdrawn[:state])
    input['withdrawn_id']=withdrawn[:operation_id]
  else
    snapshot=f[:backend].snapshot(**f[:target])
    input['operation']=T::ReadinessContract.operation(f[:request],'alicja',snapshot['accepted_match'],SecureRandom.uuid)
  end
  File.write(File.join(directory,'job.json'),JSON.generate(input),encoding:'UTF-8')
else
  input=JSON.parse(File.read(File.join(directory,job_name || 'job.json'),encoding:'UTF-8'))
  ctx.now=201
  author=ctx.workspace('Organizator')
  backend=T::LocalReadinessBackend.new(directory:File.join(directory,'k03'),actor:'Alicja',clock:-> {201},
    source:->(reference) {author.schedule_candidate(publication_ref:reference)})
  target=input['target'].transform_keys(&:to_sym)
  service=T::ReadinessService.new(port:backend,trusted_identity:backend.identity,directory:File.join(directory,'journal'),context:-> {input['context']})
  if mode=='cold-b' || mode=='no-resend'
    backend.define_singleton_method(:store) { |**| raise 'Proces B próbował ponownie wysłać operację' }
    history=T::ReadinessHistory.new(directory:File.join(directory,'journal'),context:-> {input['context']},identity:backend.identity)
    if mode=='cold-b'
      records=history.records(**target)
      assert_equal(2,records.size)
      assert_equal('attempted',records.find { |record| record['operation']['operation_id']==input['withdrawn_id'] }['status'])
    end
    assert_equal(:blocked,service.declare(request:input['request'].merge('expected_ready_revision'=>2))[:state])
    if mode=='cold-b'
      result=service.reconcile(**target,operation_id:input['withdrawn_id'])
      assert_equal(:confirmed,result[:state])
      assert_equal('withdrawn',result[:receipt]['result']['state'])
      assert_equal('ready',service.reconcile(**target,operation_id:input['ready_id'])[:receipt]['result']['state'])
      assert_equal('withdrawn',service.current(**target)[:current]['state'])
      bob=T::LocalReadinessBackend.new(directory:File.join(directory,'k03'),actor:'Bob')
      assert_equal('unknown',bob.snapshot(**target)['current']['state'])
    end
  else
    File.write(File.join(directory,"waiting-#{Process.pid}"),'ready')
    Timeout.timeout(10) { sleep(0.005) until File.file?(File.join(directory,'release')) }
    result=backend.store(operation:input['operation'])
    File.write(File.join(directory,"receipt-#{Process.pid}.json"),JSON.generate(result),encoding:'UTF-8')
    assert_equal(result,backend.lookup(operation:input['operation']))
  end
end
puts "PASS #{mode} PID=#{Process.pid}"
