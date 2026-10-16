# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
require_relative '../support/tournament_schedule_candidate'
require_relative '../../lib/tournaments/schedule_candidate'
F=TournamentReadinessFixture
candidate=TournamentScheduleCandidateFixture.build
before=JSON.generate(candidate.to_h)
F.isolated do |dir|
  p=F::Port.new; service=F.service(dir,p,F::Context.new)
  [candidate,candidate.to_h].each do |value|
    answer=service.declare(request:value)
    F.assert(answer[:state]==:blocked && p.calls.empty?,'Rzeczywisty Candidate nie jest żądaniem ani autorytetem K03')
  end
  F.assert(candidate.to_h['finality']=='unknown' && candidate.to_h['roles_teams']=='unassigned','Nie awansujemy finalności ani ról')
  F.assert(JSON.generate(candidate.to_h)==before,'Kandydat pozostaje dokładnie niezmieniony')
end
puts JSON.generate({passed:1,opis:'Rzeczywisty Candidate zachowuje granicę read-only'})
