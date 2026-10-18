# encoding: UTF-8
require_relative 'tournament_execution_plan'
require_relative 'tournament_coordination_file_port'
E = TournamentExecutionPlanFixture
F = TournamentCoordinationFixture
T = GameRoomTournaments
mode, directory = ARGV
raise 'Brak trybu/katalogu izolowanego' unless mode && directory
root = File.realpath(GameRoomTest::TemporaryDirectory.parent)
directory = File.expand_path(directory)
raise 'Katalog poza własnym scratch' unless directory.start_with?(root + '/')
FileUtils.mkdir_p(directory)
read = ->(name) { JSON.parse(File.binread(File.join(directory,name))) }
write = ->(name,value) { File.binwrite(File.join(directory,name), JSON.pretty_generate(value)) }

if mode=='a'
  proof=E.evidence
  proof['source']['matches'] << E.copy(proof['source']['matches'][0]).merge('match_id'=>'match-2')
  proof['plan']['matches'] << E.copy(proof['plan']['matches'][0]).merge('match_id'=>'match-2','execution_generation'=>'execution-2')
  proof['seal']['source_digest']=E.digest(proof['source']); proof['plan']['source_digest']=proof['seal']['source_digest']
  proof['plan_digest']=E.digest(proof.slice('scope','plan'))
  write.call('proof.json',proof); write.call('anchor.json',E.anchor(proof))
  request=E.request(proof)
  second=E.request(proof,match_id:'match-2')
  write.call('request.json',request.to_h); write.call('second-request.json',second.to_h)
  write.call('context.json',F.context)
else
  # B używa tylko plików A: nie wywołuje E.evidence ani nie nadaje nowych wersji.
  proof=read.call('proof.json')
  request=E.request(proof,expected_source:read.call('anchor.json'))
  F.assert(request.to_h.eql?(read.call('request.json')), 'Request B różny od utrwalonego A')
end
# Piny locków przed flock, nigdy odczyt uchwytu trzymanego przez Windows.
lock_name=T::CoordinationContract.digest([request.to_h['scope'],'alice'])+'.json.lock'
lock_paths=[File.join(directory,'port.json.lock')] + %w[journal new-withdrawn new-closed].map { |name| File.join(directory,name,'coordination-v1',lock_name) }
lock_paths.each do |path|
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path,File::WRONLY|File::CREAT|File::EXCL) { |file| file.write('') } unless File.exist?(path)
end
write.call('locks-before-'+mode+'.json',{'phase'=>'przed_flock','inputs'=>lock_paths.to_h { |path| [path,Digest::SHA256.file(path).hexdigest] }})
if mode=='a'
  TournamentCoordinationFilePort.new(second.to_h,state_path:File.join(directory,'port.json'),account:'alice')
end
port=TournamentCoordinationFilePort.new(request.to_h,state_path:File.join(directory,'port.json'),
  account:'alice',fault:mode=='a' ? 'create_stored' : nil)
context=read.call('context.json')
service=->(req,dir) { T::CoordinationService.new(port:port,trusted_identity:'fixture:owner',directory:File.join(directory,dir),
  registry:TournamentMatchFixture.registry,context: -> {context.merge('generation'=>req.to_h['execution_generation'])}) }

case mode
when 'a'
  result=service.call(request,'journal').request_match(request:request)
  F.assert(result[:state]==:unknown && result[:reason]==:port_unavailable, 'A nie zachowało niepewności create_stored')
  F.assert(port.endpoint_sessions.empty?, 'Fixture zgubił odpowiedź dopiero po endpoint store')
  state=read.call('port.json'); operation=state['matches']['match-1']['operations']['create_bind']
  F.assert(operation['operation_id']==result[:operation_id], 'Nie ten UUID skutku A')
  expected=T::CoordinationContract.binding!(operation,registry:TournamentMatchFixture.registry)
  write.call('a-result.json',{'pid'=>Process.pid,'state'=>result[:state],'operation_id'=>result[:operation_id],'binding'=>expected.to_h})
  journal=Dir.glob(File.join(directory,'journal','coordination-v1','*.json')).map { |path| JSON.parse(File.binread(path)) }
  F.assert(journal.flat_map { |doc| doc['operations'] }.any? { |op| op['status']=='attempted' && op['operation']['kind']=='create_bind' }, 'Brak attempted przed końcem A')
when 'b', 'b-withdrawn', 'b-closed'
  a=read.call('a-result.json'); F.assert(a['pid']!=Process.pid, 'To nadal proces A')
  result=service.call(request,'journal').reconcile(request:request)
  F.assert(result[:state]==:bound && result[:operation_id]==a['operation_id'], 'B utracił oryginalne UUID/bound')
  F.assert(result[:binding].to_h.eql?(a['binding']), 'B zwrócił inne powiązanie')
  write.call(mode+'-result.json',{'pid'=>Process.pid,'state'=>result[:state],'operation_id'=>result[:operation_id],'binding'=>result[:binding].to_h})
when 'withdrawn', 'closed'
  # Zdarzenie TESTOWEGO portu po skutku A; nie zbudowany od zera receipt B.
  port.transact do |state|
    state['matches'].each_value do |row|
      row['ready']['alice']={'state'=>mode=='withdrawn' ? 'withdrawn' : 'ready','revision'=>'ready-2'}
      row['grant']=nil
    end
    state['time']=mode=='closed' ? 200 : 150
  end
  second=E.request(proof,expected_source:read.call('anchor.json'),match_id:'match-2')
  F.assert(second.to_h.eql?(read.call('second-request.json')), 'Zmiana drugiego meczu')
  result=service.call(second,'new-'+mode).request_match(request:second)
  expected=mode=='withdrawn' ? :not_all_ready : :outside_window
  F.assert(result[:state]==:blocked && result[:reason]==expected, "Nie zablokowano nowej mutacji: #{result.inspect}")
  F.assert(Dir.glob(File.join(directory,'new-'+mode,'coordination-v1','*.json')).empty?, 'Odmowa po claim')
  write.call(mode+'-result.json',{'pid'=>Process.pid,'state'=>result[:state],'reason'=>result[:reason]})
else
  raise 'Nieznany tryb próby'
end
state=read.call('port.json')
F.assert(state['calls'].count { |row| row['kind']=='create_bind' }==1, 'Więcej niż jeden create')
F.assert(state['calls'].count { |row| row['kind']=='reserve' }==1, 'Więcej niż jedna rezerwacja')
puts "PASS zimny proces #{mode}: PID=#{Process.pid}, reserve=1, create=1"
