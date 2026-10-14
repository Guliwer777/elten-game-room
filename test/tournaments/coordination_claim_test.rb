# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F=TournamentCoordinationFixture
S=GameRoomTournaments::CoordinationService
fault=nil
File.singleton_class.prepend(Module.new do
  define_method(:rename) do |from,to|
    if fault && from.include?('coordination-v1')
      doc=JSON.parse(File.binread(from))
      record=doc['operations'].last
      if record['status']=='attempted'
        mode=fault; fault=nil
        super(from,to) if mode==:after
        raise IOError,'Symulacja niepewnego rename attempted'
      end
    end
    super(from,to)
  end
end)
[:before,:after].each do |mode|
  F.isolated do |dir|
    request=F.request;port=TournamentCoordinationPort.new(request)
    factory=-> { S.new(port:port,trusted_identity:'fixture:owner',directory:dir,registry:TournamentMatchFixture.registry,context: -> { F.context }) }
    fault=mode
    begin
      factory.call.request_match(request:request)
      raise 'Oczekiwano błędu rename'
    rescue IOError => e
      F.assert(e.message.include?('rename attempted'),'Błąd wstrzyknięty')
    end
    journal=Dir.glob(File.join(dir,'coordination-v1','*.json')).first
    F.assert(journal,'Oryginalny klucz musi przetrwać niepewny claim')
    original=JSON.parse(File.binread(journal))['operations'][0]['operation']['operation_id']
    second=factory.call.request_match(request:request)
    F.assert(second[:operation_id]==original && second[:state]==:unknown,'Tylko odczyt pierwotnego klucza')
    F.assert(port.calls.count(:reserve_before)==0,'Niepewny claim nie otrzymuje ponownie prawa do wysyłki')
  end
end
puts 'PASS rename attempted przed/po: trwały pierwotny klucz, zero ponownej mutacji'
