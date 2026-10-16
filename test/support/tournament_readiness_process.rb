# encoding: UTF-8
require_relative 'tournament_readiness_file_port'
require_relative 'tournament_readiness_faults'
F=TournamentReadinessFixture
mode,directory=ARGV
port=F::FilePort.new(directory); source=F::Context.new
klass=mode=='rename_a' ? F::FaultService : GameRoomTournaments::ReadinessService
service=klass.new(port:port,trusted_identity:'fixture:k03',directory:File.join(directory,'client'),context:source.method(:call))
case mode
when 'cold_a'
  port.hook=->(event,_) { raise GameRoomTournaments::ReadinessContract::PortUnavailable,'Utrata odpowiedzi po commit symulatora' if event==:store_after }
when 'rename_a'
  service.fault={text:'File.rename(LocalFilesystem.native(temporary),LocalFilesystem.native(@path))',nth:1,when: :after}
when 'race_a'
  port.hook=->(event,_) do
    if event==:store_before
      File.write(File.join(directory,'held'),Process.pid.to_s)
      F.assert(STDIN.gets=="kontynuuj\n",'Jawna bariera procesu A')
    end
  end
end
if %w[cold_b rename_b].include?(mode)
  previous=JSON.parse(File.read(File.join(directory,mode.sub('_b','_a')+'.json')))
  answer=service.reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:previous['result']['operation_id'])
else
  answer=service.declare(request:F.request(mode=='race_b' ? 'withdrawn' : 'ready'))
end
File.write(File.join(directory,mode+'.json'),JSON.generate({pid:Process.pid,mode:mode,result:answer}),encoding:'UTF-8')
puts JSON.generate({pid:Process.pid,mode:mode,result:answer})
