require_relative '../support/assertions'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/registration_projection'
include GameRoomTest::Assertions
T = GameRoomTournaments

draft = {'name' => 'Boundary', 'game_id' => 'tic_tac_toe', 'game_options' => {},
  'format' => 'round_robin', 'rematch' => false, 'players_per_match' => 2,
  'pairing' => 'balanced_cycle', 'windows' => [], 'starts_at' => 0, 'deadline_at' => 0}
publication = T::Publication.from_draft(draft: draft, registry: GameRoomGames::CATALOG,
  publication_key: 'boundary', rules: 'Rules', registration_opens_at: 100,
  registration_closes_at: 0, timezone: 'Europe/Warsaw').to_row.merge(
    '__id' => 10, '__insertion_user' => 'owner', '__insertion_time' => 90)
publication = T::Publication.project(rows: [publication], registry: GameRoomGames::CATALOG,
  complete: true).fetch('announcements').first
generation = T::RegistrationProjection.publication_generation(publication)
row = lambda do |id, actor, key, kind, fields = {}|
  {'tournament_id' => 10, 'operation_key' => key, 'kind' => kind,
    '__id' => id, '__insertion_user' => actor, '__insertion_time' => 100 + id}.merge(fields)
end
joins = %w[alice bob carol].each_with_index.map { |actor, i| row.call(i + 1, actor, "join-#{actor}", 'join') }
build = lambda do |rows, publications = [publication]|
  T::RegistrationProjection.build(announcements: publications, registrations: joins + rows,
    registry: GameRoomGames::CATALOG, complete: true)
end
cases = {
  'removal' => [{'account' => 'alice'}, {'account' => 'bob'}],
  'pairing' => %w[bob carol].map { |partner| {'account' => 'alice', 'partner' => partner,
    'pairing_generation' => T::RegistrationProjection.pairing_generation(%w[alice bob carol], {})} },
  'cancellation' => [{'publication_generation' => generation}, {'publication_generation' => 'd' * 64}],
  'amendment' => %w[One Two].map { |name| {'publication_generation' => generation,
    'amendment_json' => JSON.generate(publication.slice(*T::Publication::COLUMNS).merge('title' => name))} }
}
cases.each do |kind, payloads|
  rows = payloads.each_with_index.map { |payload, i| row.call(20 + i, 'owner', 'same-intent', kind, payload) }
  original = Marshal.dump([publication, joins, rows])
  view = build.call(rows)
  assert_equal('conflict', view.operation_status(tournament_id: 10, account: 'owner', operation_key: 'same-intent'), kind)
  assert_equal(%w[alice bob carol], view.to_h.fetch('members').map { |person| person.fetch('account') }, kind)
  assert_equal('Boundary', view.to_h.fetch('announcements').first.fetch('title'), kind)
  assert_equal(view.to_h, build.call(rows.reverse).to_h, 'Conflict depended on row order')
  assert_equal(original, Marshal.dump([publication, joins, rows]), 'Projection changed its inputs')

  # Retrying the same action, including through an alias, remains idempotent.
  same = [rows.first, rows.first.merge('__id' => 22, '__insertion_time' => 122, 'tournament_id' => 11)]
  aliases = [publication, publication.merge('__id' => 11)]
  accepted = build.call(same, aliases)
  assert_equal('confirmed', accepted.operation_status(tournament_id: 11, account: 'owner', operation_key: 'same-intent'), kind)
  assert_equal([20, 22], accepted.to_h.fetch('operations').find { |operation| operation['account'] == 'owner' }.fetch('record_ids'))
  assert_equal(accepted.to_h, build.call(same.reverse, aliases.reverse).to_h)
end

[nil, false, 1, {}, [], '{', '{"title":1,"title":2}', '[]', 'null', '1', '"text"', '[' * 10 + '0' + ']' * 10].each do |payload|
  bad = row.call(30, 'owner', 'malformed', 'amendment',
    'publication_generation' => generation, 'amendment_json' => payload)
  view = build.call([bad])
  assert_equal('unconfirmed', view.operation_status(tournament_id: 10, account: 'owner', operation_key: 'malformed'))
  assert_equal(%w[alice bob carol], view.to_h.fetch('members').map { |person| person.fetch('account') })
  assert_equal('Boundary', view.to_h.fetch('announcements').first.fetch('title'))
  assert(view.to_h.dig('diagnostics', 'registrations').any? { |diagnostic| diagnostic['code'] == 'invalid_amendment' })
end

valid = row.call(40, 'owner', 'mixed', 'amendment', cases.fetch('amendment').first)
bad = valid.merge('__id' => 41, 'amendment_json' => '{')
assert_equal('conflict', build.call([valid, bad]).operation_status(tournament_id: 10, account: 'owner', operation_key: 'mixed'))
assert_equal('Boundary', build.call([valid, bad]).to_h.fetch('announcements').first.fetch('title'))
puts 'PASS registration mutations: changed targets/payload conflict, stable retries/aliases, malformed amendment isolation and immutable source'
