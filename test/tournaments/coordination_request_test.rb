# encoding: UTF-8
require_relative '../support/tournament_coordination_fixture'
F = TournamentCoordinationFixture
F.assert(defined?(GameRoomTournaments::CoordinationRequest), 'Brak odrębnego request przed native UUID')
R = GameRoomTournaments::CoordinationRequest
registry = TournamentMatchFixture.registry
[['uno', %w[Alice Bob]], ['three_five_eight', %w[Alice Bob Carol]]].each do |game, names|
  input = F.request(game: game, names: names)
  model = R.build(input, registry: registry)
  F.assert(model.to_h.eql?(input), 'Pełne role/opcje bez defaults')
  F.assert(!model.is_a?(GameRoomTournaments::MatchBinding), 'Przed create to nie binding')
  input['players'][0]['username'].replace('Inny')
  F.assert(model.to_h['players'][0]['username'] == 'Alice', 'Odłączony snapshot')
  F.assert(model.to_h['options'].frozen?, 'Głęboka niezmienność')
end
mutations = [->(p) { p['state']='observed_candidate' }, ->(p) { p['roles_status']='unassigned' },
  ->(p) { p['players'][1]['seat']=0 }, ->(p) { p['players'][0]['account']='owner' },
  ->(p) { p['options']={} }, ->(p) { p['options']['draw_responses']='true' },
  ->(p) { p['game_id']='unknown' }, ->(p) { p['window']['closes']=100.0 },
  ->(p) { p['players'][0]['game_role']='unassigned' }, ->(p) { p['seal_id']=nil }]
mutations.each do |change|
  p=F.request; change.call(p)
  F.assert(TournamentMatchFixture.invalid { R.build(p,registry:registry) }, 'Odrzuć niepełne dane')
end
puts 'PASS request: 2/3 osoby, rzeczywisty rejestr, brak fikcyjnego bindingu, błędne plany odrzucone'
