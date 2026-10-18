# encoding: UTF-8
require_relative '../support/tournament_coordination_file_port'
require 'rbconfig'
F=TournamentCoordinationFixture
sequence=0
children=[]
spawn_child=->(request,state,dir,account,mode='request',fault='',barrier='') do
  sequence+=1
  evidence=ENV.fetch('COORD_EVIDENCE_DIR')
  prefix=File.join(evidence,"child-#{sequence}")
  command=[RbConfig.ruby,File.expand_path('../support/tournament_coordination_process.rb',__dir__),request,state,dir,account,mode,fault,barrier]
  pid=Process.spawn(*command,out:prefix+'.stdout.raw',err:prefix+'.stderr.raw')
  child=[pid,prefix,command]
  children << child
  child
end
finish=->(child) do
  pid,prefix,command=child
  _,status=Process.wait2(pid)
  children.delete(child)
  File.write(prefix+'.command.json',JSON.pretty_generate({pid:pid,command:command,exit:status.exitstatus,
    env:ENV.to_h.slice('TMPDIR','TMP','TEMP','GEM_PATH','GEM_HOME','RUBYLIB','RUBYOPT','ELTEN_HOST_SOURCE','ELTEN_ZSTD_LIBRARY','COORD_EVIDENCE_DIR')}))
  F.assert(status.success?,"Dziecko #{pid}: #{File.binread(prefix+'.stderr.raw')}")
  File.binwrite(prefix+'.request.raw',File.binread(command[2]))
  File.binwrite(prefix+'.service-state.raw',File.binread(command[3])) if File.file?(command[3])
  Dir.glob(File.join(command[4],'coordination-v1','*.json')).each_with_index do |path,index|
    File.binwrite(prefix+".journal-#{index}.raw",File.binread(path))
  end
  JSON.parse(File.binread(prefix+'.stdout.raw'))
end
isolated=->(&block) do
  F.isolated do |dir|
    begin
      block.call(dir)
    ensure
      cleanup_errors=[]
      children.dup.each do |child|
        begin
          barrier=child[2].last
          File.write(barrier+'.release','go') unless barrier.empty?
        rescue StandardError => error
          cleanup_errors << error
        end
        begin
          finish.call(child)
        rescue StandardError => error
          cleanup_errors << error
        end
      end
      raise cleanup_errors.first if cleanup_errors.one?
      unless cleanup_errors.empty?
        message=cleanup_errors.map { |error| error.full_message(highlight:false) }.join("\n")
        raise RuntimeError.new(message), cause: $! || cleanup_errors.first
      end
    end
  end
end
wait_file=->(path) do
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+20
  until File.exist?(path)
    raise "Brak bariery #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.01
  end
end
%w[create_stored create_after].each do |fault|
  isolated.call do |dir|
    path=File.join(dir,'request.json');File.write(path,JSON.generate(F.request))
    state=File.join(dir,'service.json'); local=File.join(dir,'alice')
    a=finish.call(spawn_child.call(path,state,local,'alice','request',fault))
    F.assert(a['state']=='unknown','A utracił odpowiedź')
    b=finish.call(spawn_child.call(path,state,local,'alice','reconcile'))
    F.assert(a['pid']!=b['pid'] && b['state']=='bound' && b['binding'],'Cold A→B kończy się bindingiem')
    F.assert(a['operation_id']==b['operation_id'],'Cold zachowuje operation_id')
    F.assert((fault=='create_stored' ? a['endpoint_sessions'].empty? : a['endpoint_sessions'].size==1),'Granica przed/po endpoint store')
    successor=finish.call(spawn_child.call(path,state,File.join(dir,'bob'),'bob'))
    F.assert(successor['state']=='bound' && successor['operation_id']==a['operation_id'],'Następca czyta shared stary klucz')
    calls=JSON.parse(File.binread(state))['calls']
    F.assert(calls.count { |c| c['kind']=='create_bind' }==1,'Cold/next account zero drugiego create')
  end
end
isolated.call do |dir|
  path=File.join(dir,'request.json');File.write(path,JSON.generate(F.request))
  state=File.join(dir,'service.json');local=File.join(dir,'alice');barrier=File.join(dir,'barrier')
  a=spawn_child.call(path,state,local,'alice','hold','',barrier)
  wait_file.call(barrier+'.held')
  b=finish.call(spawn_child.call(path,state,local,'alice'))
  F.assert(b['reason']=='local_busy','Procesowy flock obejmuje całą próbę')
  File.write(barrier+'.release','go')
  first=finish.call(a)
  F.assert(first['state']=='bound','Zwycięzca kończy pełny pion')
end
isolated.call do |dir|
  ab=F.request;ac=F.request(names:%w[Alice Carol]);ac['match_id']='match-AC'
  paths=[ab,ac].each_with_index.map { |r,i| p=File.join(dir,"request-#{i}.json");File.write(p,JSON.generate(r));p }
  state=File.join(dir,'service.json');barrier=File.join(dir,'race')
  a=spawn_child.call(paths[0],state,File.join(dir,'alice'),'alice','race','',barrier)
  b=spawn_child.call(paths[1],state,File.join(dir,'carol'),'carol','race','',barrier)
  wait_file.call(barrier+'.alice');wait_file.call(barrier+'.carol');File.write(barrier+'.release','go')
  results=[finish.call(a),finish.call(b)]
  F.assert(results.count { |r| r['state']=='bound' }==1 && results.count { |r| r['state']=='conflict' }==1,'AB kontra AC: jeden grant')
  server=JSON.parse(File.binread(state));loser=results.find { |r| r['state']=='conflict' }['pid']
  F.assert(server['calls'].none? { |c| c['kind']=='create_bind' && c['pid']==loser },'Przegrany zero create')
  F.assert(server['busy'].size==2,'Cały skład zwycięzcy albo nikt')
end
isolated.call do |dir|
  path=File.join(dir,'request.json');File.write(path,JSON.generate(F.request))
  state=File.join(dir,'service.json');local=File.join(dir,'alice')
  a=finish.call(spawn_child.call(path,state,local,'alice','request','reserve_after'))
  b=finish.call(spawn_child.call(path,state,local,'alice','reconcile'))
  F.assert(a['pid']!=b['pid'] && a['state']=='unknown' && b['state']=='reserved','Cold rezerwacja po store')
  F.assert(a['operation_id']==b['operation_id'],'Pierwotny klucz rezerwacji')
  successor=finish.call(spawn_child.call(path,state,File.join(dir,'bob'),'bob'))
  F.assert(successor['reason']=='takeover_required','Bez nowego grantu następca jawnie blocked')
  server=JSON.parse(File.binread(state))
  F.assert(server['calls'].count { |c| c['kind']=='reserve' }==1 && server['calls'].none? { |c| c['kind']=='create_bind' },'Cold reserve bez drugiej mutacji')
end
isolated.call do |dir|
  path=File.join(dir,'request.json');File.write(path,JSON.generate(F.request))
  state=File.join(dir,'service.json');local=File.join(dir,'alice')
  a=finish.call(spawn_child.call(path,state,local,'alice','request','create_before'))
  b=finish.call(spawn_child.call(path,state,local,'alice'))
  F.assert(a['pid']!=b['pid'] && a['state']=='unknown' && b['state']=='unknown','Cold create przed store pozostaje unknown')
  F.assert(a['operation_id']==b['operation_id'],'Nie generuj nowego klucza')
  F.assert(JSON.parse(File.binread(state))['calls'].none? { |c| c['kind']=='create_bind' },'Brak automatycznego retry przed store')
end
puts 'PASS cold różne PID, shared następca, procesowy claim i kolizja AB/AC (wyłącznie symulacja)'
