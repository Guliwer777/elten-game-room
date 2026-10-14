# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
F.isolated do |dir|
  port=F::Port.new; source=F::Context.new; service=F.service(dir,port,source)
  first=service.declare(request:F.request)
  F.assert(first[:state]==:confirmed, 'Pierwsza gotowość potwierdzona')
  second=service.declare(request:F.request('withdrawn',1))
  F.assert(second[:state]==:confirmed && second[:receipt]['result']['state']=='withdrawn', 'Odrębne legalne wycofanie po potwierdzeniu')
  F.assert(first[:operation_id]!=second[:operation_id], 'Nie jeden UUID na całe życie meczu')
  F.assert(second[:receipt]['result']['ready_revision'].eql?(2), 'Nowa rewizja po wycofaniu')
  F.assert(port.calls.count(:store_before)==2, 'Dokładnie dwie świadome decyzje')
  own=service.current(scope:F.scope,match_ref:F.match_ref)
  F.assert(own[:current]['state']=='withdrawn', 'Bieżący odczyt własnego wycofania')
end
puts JSON.generate({passed:1,opis:'ready→confirmed→withdrawn→confirmed'})
