# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
handles=[];context=nil;point=nil
File.singleton_class.prepend(Module.new do
  define_method(:open) do |path,*args,**kwargs,&block|
    value=super(path,*args,**kwargs,&block)
    if value.is_a?(File) && path.to_s.include?('coordination-v1')
      handles << value
      if point && (point==:lock ? path.to_s.end_with?('.lock') : path.to_s.include?('.tmp-'))
        context['epoch']+=2
        point=nil
      end
    end
    value
  end
end)
[:lock,:temp].each do |at|
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request);context=F.context;point=at
    service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { context })
    result=service.request_match(request:request)
    F.assert(result[:state]==:blocked,'Epoka zmieniona podczas lokalnego I/O')
    F.assert(handles.all?(&:closed?),"Własny uchwyt #{at} nie może zginąć przed kontrolą po open")
    F.assert(!port.calls.include?(:reserve_before),'Przy zmianie kontekstu zero mutacji')
  end
end
puts 'PASS epoka podczas File.open: lokalne zasoby zwolnione, bez reserve'
