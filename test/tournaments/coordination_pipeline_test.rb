# encoding: UTF-8
require_relative '../support/tournament_coordination_port'
F = TournamentCoordinationFixture
S = GameRoomTournaments::CoordinationService
[['uno',%w[Alice Bob]],['three_five_eight',%w[Alice Bob Carol]]].each do |game,names|
  F.isolated do |dir|
    request=F.request(game:game,names:names)
    port=TournamentCoordinationPort.new(request)
    service=S.new(port:port,trusted_identity:'fixture:owner',directory:dir,
      registry:TournamentMatchFixture.registry,context: -> { F.context })
    result=service.request_match(request:request)
    F.assert(result[:state]==:bound, "Pion powinien kończyć się bound: #{result.inspect}")
    F.assert(result[:binding].is_a?(GameRoomTournaments::MatchBinding), 'Rzeczywisty builder MatchBinding')
    binding=result[:binding].to_h
    F.assert(binding['players'].eql?(request['players']) && binding['options'].eql?(request['options']), 'Dokładny spec')
    F.assert(!result.key?(:start_allowed), 'Brak prawa startu')
    F.assert(port.calls.count(:reserve_before)==1 && port.calls.count(:create_before)==1, 'Jedna rezerwacja i create')
    repeated=service.request_match(request:request)
    F.assert(repeated[:binding].to_h.eql?(binding), 'Powtórzony callback wraca do tego samego bindingu')
    F.assert(port.calls.count(:create_before)==1, 'Brak drugiego create')
    F.assert(Dir.glob(File.join(dir,'**','*.json')).size==1, 'Własny trwały journal')
  end
end
puts 'PASS pion 2/3 osoby: sealed/allready → durable reserve → exact create/readback → MatchBinding'
