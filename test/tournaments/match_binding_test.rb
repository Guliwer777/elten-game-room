# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/assertions'
include GameRoomTest::Assertions
require_relative '../support/tournament_match_data'
path = File.expand_path('../../lib/tournaments/match_binding.rb', __dir__)
require path if File.file?(path)
assert(defined?(GameRoomTournaments::MatchBinding), 'Brak DTO MatchBinding')
fixture = TournamentMatchFixture
raw = fixture.payload
binding = GameRoomTournaments::MatchBinding.build(raw, registry: fixture.registry)
assert(binding.frozen? && binding.to_h.frozen?, 'DTO musi być zamrożony')
raw['players'][0]['username'].replace('Mallory')
assert(binding.to_h['players'][0]['username'] == 'Alice', 'DTO dzieli dane wejścia')
assert(binding.to_h['options'].frozen? && binding.to_h['players'][0]['username'].frozen?, 'Płytkie zamrożenie')
assert(!binding.respond_to?(:start_allowed) && !binding.to_h.key?('start_allowed'), 'Dane nie są grantem')
three = GameRoomTournaments::MatchBinding.build(fixture.payload(game_id: 'three_five_eight', names: %w[Alice Bob Carol]), registry: fixture.registry)
assert(three.to_h['players'].size == 3, 'Zgubiono trzecią osobę')
seats = fixture.payload
seats['players'][0]['seat'], seats['players'][1]['seat'] = 1, 0
assert(GameRoomTournaments::MatchBinding.build(seats, registry: fixture.registry).to_h['players'].map { |p| p['seat'] } == [1, 0],
  'DTO narzuca kolejność miejsc zamiast zachować jawne przypisanie')
expanded = fixture.payload(names: ["İ" * 64, 'Bob'])
assert(GameRoomTournaments::MatchBinding.build(expanded, registry: fixture.registry).to_h['players'][0]['account'] == ("İ" * 64).downcase, 'Unicode raw/canonical')
mutations = [
  ->(x) { x['contract_version'] = 1.0 }, ->(x) { x['leg'] = '1' },
  ->(x) { x['table_id'] = '42' }, ->(x) { x['roles_status'] = 'unassigned' },
  ->(x) { x['players'][1]['seat'] = 0 }, ->(x) { x['players'][0]['account'] = 'Alice' },
  ->(x) { x['players'][0].delete('team') }, ->(x) { x['options'] = {} },
  ->(x) { x['options']['draw_responses'] = 1 }, ->(x) { x['reservation']['fencing'] = true },
  ->(x) { x['reservation']['ready_versions'].delete('bob') },
  ->(x) { x['native_uuid'] = 'not-a-uuid' }, ->(x) { x['start_allowed'] = true },
  ->(x) { x['players'][0]['game_role'] = 'unassigned' },
  ->(x) { x['players'][0]['team'] = 'NIEUSTALONE' },
  ->(x) { x['plan_id'] = 'x' * 70_000 }, ->(x) { x['players'][0]['username'] = 'x' * 65 }
]
mutations.each_with_index do |mutation, index|
  candidate = fixture.payload
  mutation.call(candidate)
  assert(fixture.invalid { GameRoomTournaments::MatchBinding.build(candidate, registry: fixture.registry) }, "Przyjęto wadliwe dane #{index}")
end
puts 'PASS MatchBinding: detached, deep immutable, pełny skład, Unicode, strict types, bounded, brak authority'
