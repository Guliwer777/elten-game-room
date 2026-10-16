# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
fault=nil
File.singleton_class.prepend(Module.new do
  define_method(:rename) do |from,to|
    if fault && from.include?('coordination-v1')
      record=JSON.parse(File.binread(from))['operations'].last
      if record['status']=='confirmed' && record['operation']['kind']=='create_bind'
        mode=fault;fault=nil
        super(from,to) if mode==:after
        raise IOError,'Symulacja lokalnego confirm failure'
      end
    end
    super(from,to)
  end
end)
[:before,:after].each do |mode|
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request)
    factory=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context }) }
    fault=mode;failed=false
    begin
      factory.call.request_match(request:request)
    rescue IOError => e
      failed=e.message.include?('confirm failure')
    end
    F.assert(failed && port.endpoint_sessions.size==1,'Zdalny sukces, lokalny błąd')
    original=port.operations['create_bind']['operation_id']
    result=factory.call.reconcile(request:request)
    F.assert(result[:state]==:bound && result[:operation_id]==original,'Readback oryginalnego klucza po błędzie confirm')
    F.assert(port.calls.count(:create_before)==1,'Bez drugiej mutacji')
  end
end
puts 'PASS zdalny sukces → local confirm failure przed/po rename → exact MatchBinding'
