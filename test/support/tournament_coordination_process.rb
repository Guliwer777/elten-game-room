# encoding: UTF-8
require_relative 'tournament_coordination_file_port'
request_path,state_path,directory,account,mode,fault,barrier=ARGV
request=JSON.parse(File.binread(request_path))
port=TournamentCoordinationFilePort.new(request,state_path:state_path,account:account,fault:fault)
if mode=='hold'
  port.hook=->(event,_) do
    if event==:reserve_before
      File.write(barrier+'.held',Process.pid.to_s)
      deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+20
      until File.exist?(barrier+'.release')
        raise 'Timeout bariery fixture' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
        sleep 0.01
      end
    end
  end
elsif mode=='race'
  File.write(barrier+'.'+account,Process.pid.to_s)
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+20
  until File.exist?(barrier+'.release')
    raise 'Timeout bariery fixture' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.01
  end
end
service=GameRoomTournaments::CoordinationService.new(port:port,trusted_identity:'fixture:owner',directory:directory,
  registry:TournamentMatchFixture.registry,context: -> { TournamentCoordinationFixture.context(account:account) })
result=mode=='reconcile' ? service.reconcile(request:request) : service.request_match(request:request)
puts JSON.generate(result.merge(binding:result[:binding]&.to_h,pid:Process.pid,endpoint_sessions:port.endpoint_sessions))
