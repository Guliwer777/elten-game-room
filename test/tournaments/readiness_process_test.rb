# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'digest'
F=TournamentReadinessFixture
base=Dir.mktmpdir('k03-procesy-',ENV.fetch('ENTRY_SCRATCH'))
receipts=[]
launch=->(mode,dir) do
  command=[RbConfig.ruby,File.expand_path('../support/tournament_readiness_process.rb',__dir__),mode,dir]
  stdin,stdout,stderr,thread=Open3.popen3(*command)
  [stdin,stdout,stderr].each(&:binmode)
  {command:command,stdin:stdin,stdout:stdout,stderr:stderr,thread:thread,mode:mode,dir:dir}
end
join=->(child) do
  child[:stdin].close unless child[:stdin].closed?
  out_reader=Thread.new { child[:stdout].read }; err_reader=Thread.new { child[:stderr].read }
  status=Timeout.timeout(20) { child[:thread].value }
  out=out_reader.value; err=err_reader.value
  out.force_encoding('UTF-8'); err.force_encoding('UTF-8')
  F.assert(out.valid_encoding? && err.valid_encoding?,'Surowe kanały dzieci UTF-8')
  child[:stdout].close; child[:stderr].close
  prefix=File.join(ENV.fetch('ENTRY_EVIDENCE'),"dziecko-#{status.pid}")
  File.binwrite(prefix+'.stdout.raw',out); File.binwrite(prefix+'.stderr.raw',err)
  record={command:child[:command],cwd:Dir.pwd,env:ENV.to_h.select { |k,_| %w[HOME USERPROFILE APPDATA LOCALAPPDATA TMPDIR TMP TEMP ENTRY_EVIDENCE ENTRY_SCRATCH RUBYOPT GEM_HOME GEM_PATH RUBYLIB ELTEN_HOST_SOURCE ELTEN_ZSTD_LIBRARY].include?(k) },pid:status.pid,exit:status.exitstatus,joined:true,stdout_sha256:Digest::SHA256.hexdigest(out),stderr_sha256:Digest::SHA256.hexdigest(err)}
  receipts << record
  File.write(File.join(ENV.fetch('ENTRY_EVIDENCE'),'children.json'),JSON.pretty_generate(receipts),encoding:'UTF-8')
  F.assert(status.success?,"Dziecko #{child[:mode]}: #{err}")
  JSON.parse(File.read(File.join(child[:dir],child[:mode]+'.json')))
end
passed=[]
%w[cold rename].each do |prefix|
  dir=File.join(base,prefix); Dir.mkdir(dir)
  a=join.call(launch.call(prefix+'_a',dir))
  b=join.call(launch.call(prefix+'_b',dir))
  F.assert(a['pid']!=b['pid'],'B jest nowym procesem, A zakończony')
  F.assert(a['result']['state']=='unknown','A zakończył się z niepewnością')
  F.assert(a['result']['operation_id']==b['result']['operation_id'],'B otrzymał tylko pliki i ten sam UUID')
  F.assert(b['result']['state']==(prefix=='cold' ? 'confirmed' : 'unknown'),'Wynik odpowiada trwałym plikom serwera')
  data=JSON.parse(File.read(File.join(dir,'test-server.json')))
  F.assert(data['calls'].count('store_before')==(prefix=='cold' ? 1 : 0),'Zero resend procesu B')
  passed << prefix
end
dir=File.join(base,'race'); Dir.mkdir(dir)
a=launch.call('race_a',dir)
b=nil; answer_b=nil
begin
  Timeout.timeout(10) { sleep(0.01) until File.exist?(File.join(dir,'held')) }
  b=launch.call('race_b',dir)
  answer_b=join.call(b)
ensure
  a[:stdin].write("kontynuuj\n"); a[:stdin].flush
  answer_a=join.call(a)
end
F.assert(answer_a['result']['state']=='confirmed','Właściciel wyścigu zakończył')
F.assert(answer_b['result']['reason']=='local_busy','Drugi rzeczywisty proces bez prawa wysłania')
remote=JSON.parse(File.read(File.join(dir,'test-server.json')))
F.assert(remote['calls'].count('store_before')==1,'Wyścig przeciwnych deklaracji bez duplikatu')
passed << 'race'
puts JSON.generate({passed:passed.size,cases:passed,proof_directory:base,children:receipts.map { |r| r.slice(:pid,:exit,:joined) }})
