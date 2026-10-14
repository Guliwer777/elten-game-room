# encoding: UTF-8
require_relative '../support/tournament_coordination_fix_cases'
T=TournamentCoordinationFixCases
cases={}
%i[request_match reconcile].each do |method|
  %i[relative before_first mutable_before mutable_after absolute].each do |mode|
    cases["#{method}-#{mode}"]=->(dir,data) do
      a=File.join(dir,'A');b=File.join(dir,'B');c=File.join(dir,'C');FileUtils.mkdir_p([a,b,c])
      request=T::F.request;port=TournamentCoordinationPort.new(request)
      port.hook=->(event,_) { raise T::C::PortUnavailable,'Przed reserve store' if event==:reserve_before }
      source=mode==:absolute ? File.join(a,'client-data') : +'client-data'
      service=Dir.chdir(a) { T.service(port,source) }
      source.replace(File.join(b,'other-data')) if mode==:mutable_before
      first=Dir.chdir(mode==:before_first ? b : a) { service.request_match(request:request) }
      source.replace(File.join(b,'other-data')) if mode==:mutable_after
      second=Dir.chdir(b) { service.public_send(method,request:request) }
      third=Dir.chdir(c) { service.public_send(method,request:request) }
      data.merge!(first:T.result(first),second:T.result(second),third:T.result(third),calls:port.calls)
      T.assert(first[:state]==:unknown,'Unknown po pierwszym reserve')
      T.assert([second,third].all? { |v| v[:state]==:unknown && v[:operation_id]==first[:operation_id] },'Po cwd/mutacji tylko dokładny oryginalny klucz')
      T.assert(T.mutations(port)==[1,0],'Zero dodatkowych reserve/create')
      journals=Dir.glob(File.join(dir,'**','*.json'))
      T.assert(journals.size==1 && journals.first.start_with?(File.join(a,'client-data')+'/'),'Baza odłączona i związana z konstruktorem, nie pierwszą próbą')
      record=JSON.parse(File.binread(journals.first))['operations'].fetch(0)
      T.assert(record['status']=='attempted' && record['operation']['operation_id']==first[:operation_id],'Attempted nie usunięto ani nie zresetowano')
    end
  end
end
[nil,7,'',"bad\0directory",'x'*4097,"\xFF".b.force_encoding('UTF-8'),'C:relative','//server/share','\\\\server\\share'].each_with_index do |source,index|
  cases["invalid-directory-#{index}"]=->(dir,data) do
    port=TournamentCoordinationPort.new(T::F.request)
    rejected=false
    begin
      value=T.service(port,source).request_match(request:T::F.request)
      rejected=value[:state]==:blocked
    rescue GameRoomTournaments::Publication::Invalid
      rejected=true
    end
    data[:calls]=port.calls
    T.assert(rejected && T.mutations(port)==[0,0],'Nie normalizuj niedozwolonego directory przed walidacją')
    T.assert(Dir.children(dir).empty?,'Bez plików dla błędnego wejścia')
  end
end
T.run(cases,'directory')
