# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
F.assert(defined?(GameRoomTournaments::ReadinessService), 'Brak klienta odczytu własnej gotowości K03')
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new
  value=F.service(dir,port,source).current(scope:F.scope,match_ref:F.match_ref)
  F.assert(value[:state]==:confirmed, 'Odczyt autorytatywnego snapshotu')
  F.assert(value[:current]['state']=='unknown', 'Nieznana gotowość nie jest wycofaniem')
  F.assert(value[:current]['ready_revision'].eql?(0), 'Jawna rewizja początkowa')
  F.assert(Dir.children(dir).empty?, 'Odczyt nie tworzy intencji')
  F.assert(port.calls==[:negotiate,:snapshot], 'Tylko odczyty portu')
end
puts JSON.generate({passed:1,opis:'Własny odczyt K03 bez domyślnego withdrawn'})
