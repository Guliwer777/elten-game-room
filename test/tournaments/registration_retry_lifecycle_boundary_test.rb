require_relative '../support/assertions'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/registration_projection'
include GameRoomTest::Assertions

T = GameRoomTournaments
registry = GameRoomGames::CATALOG
draft = {'name' => 'Original', 'game_id' => 'tic_tac_toe', 'game_options' => {},
  'format' => 'round_robin', 'rematch' => false, 'players_per_match' => 2,
  'pairing' => 'balanced_cycle', 'windows' => [], 'starts_at' => 0, 'deadline_at' => 0}
original = T::Publication.from_draft(draft: draft, registry: registry,
  publication_key: 'retry-lifecycle', rules: 'Rules', registration_opens_at: 100,
  registration_closes_at: 0, timezone: 'Europe/Warsaw').to_row
publications = [original.merge('__id' => 10, '__insertion_user' => 'Owner', '__insertion_time' => 80),
  original.merge('__id' => 11, '__insertion_user' => 'owner', '__insertion_time' => 81),
  original.merge('__id' => 12, '__insertion_user' => 'Other', '__insertion_time' => 82)]
row = lambda do |id, actor, key, kind = 'join', fields = {}|
  {'__id' => id, '__insertion_user' => actor, '__insertion_time' => 100 + id,
    'tournament_id' => 10, 'operation_key' => key, 'kind' => kind}.merge(fields)
end
joins = %w[alice bob carol].each_with_index.map { |person, i| row.call(i + 1, person, "join-#{person}") }
joins << row.call(4, 'alice', 'join-alice-other', 'join', 'tournament_id' => 12)
build = lambda do |extra, announcements = publications|
  T::RegistrationProjection.build(announcements: announcements, registrations: joins + extra,
    registry: registry, complete: true)
end
members = ->(view, id) { view.to_h.fetch('members').select { |person| person['tournament_id'] == id }.map { |person| person['account'] } }
publication = ->(view, id) { view.to_h.fetch('announcements').find { |item| item['__id'] == id } }

# A changed pairing generation is a different intent even when both partners
# happen to be the same. It cannot turn one request into mutual consent.
generation = T::RegistrationProjection.pairing_generation(%w[alice bob carol], {})
pair = row.call(20, 'Alice', 'pair-once', 'pairing',
  'account' => 'ALICE', 'partner' => 'BOB', 'pairing_generation' => generation)
reciprocal = row.call(22, 'Bob', 'bob-accepts', 'pairing',
  'account' => 'bob', 'partner' => 'alice', 'pairing_generation' => generation)
retried_pair = pair.merge('__id' => 21, '__insertion_user' => 'alice', '__insertion_time' => 121,
  'tournament_id' => 11, 'account' => 'alice', 'partner' => 'bob', '__ignored' => 'server metadata')
confirmed = build.call([pair, retried_pair, reciprocal])
assert_equal('confirmed', confirmed.operation_status(tournament_id: 11, account: 'ALICE', operation_key: 'pair-once'))
assert_equal([{'tournament_id' => 10, 'accounts' => %w[alice bob]}], confirmed.to_h.fetch('pairs'))
lower_alias = publications.first.merge('__id' => 1, '__insertion_time' => 79)
renumbered = build.call([pair, retried_pair, reciprocal], publications + [lower_alias])
assert_equal('confirmed', renumbered.operation_status(tournament_id: 11, account: 'alice', operation_key: 'pair-once'))
assert_equal([{'tournament_id' => 1, 'accounts' => %w[alice bob]}], renumbered.to_h.fetch('pairs'))
assert_equal(%w[alice bob carol], members.call(renumbered, 1))
assert_equal(['alice'], members.call(renumbered, 12))
assert_equal(confirmed.retention_history(10).fetch(:events), renumbered.retention_history(1).fetch(:events),
  'A newly visible publication alias renewed or dropped registration activity')
changed = retried_pair.merge('pairing_generation' => 'd' * 64)
conflicting = build.call([pair, changed, reciprocal])
assert_equal('conflict', conflicting.operation_status(tournament_id: 10, account: 'alice', operation_key: 'pair-once'))
assert_equal([], conflicting.to_h.fetch('pairs'))
assert_equal([{'tournament_id' => 10, 'from' => 'bob', 'to' => 'alice'}], conflicting.to_h.fetch('pair_requests'))
assert_equal(%w[alice bob carol], members.call(conflicting, 10))

# A late retry of an older amendment must not undo the newer amendment. A
# same-key changed base must instead invalidate that operation as a whole.
checked_original = publication.call(build.call([]), 10).slice(*T::Publication::COLUMNS)
base = T::RegistrationProjection.publication_generation(checked_original)
first_content = checked_original.merge('title' => 'First')
first = row.call(30, 'Owner', 'first-edit', 'amendment',
  'publication_generation' => base, 'amendment_json' => JSON.generate(first_content))
second = row.call(31, 'owner', 'second-edit', 'amendment',
  'publication_generation' => T::RegistrationProjection.publication_generation(first_content),
  'amendment_json' => JSON.generate(first_content.merge('title' => 'Second')))
late = first.merge('__id' => 32, '__insertion_time' => 132, 'tournament_id' => 11)
versions = build.call([first, second, late])
assert_equal('Second', publication.call(versions, 10).fetch('title'))
assert_equal('Original', publication.call(versions, 12).fetch('title'))
assert_equal('confirmed', versions.operation_status(tournament_id: 11, account: 'owner', operation_key: 'first-edit'))
assert_equal([130, 131], versions.retention_history(10).fetch(:events).filter_map { |event| event[:time] if event[:publication] })
different_base = build.call([first, second, late.merge('publication_generation' => 'a' * 64)])
assert_equal('conflict', different_base.operation_status(tournament_id: 10, account: 'owner', operation_key: 'first-edit'))
assert_equal('Original', publication.call(different_base, 10).fetch('title'))

# Invalid data is isolated by authenticated author, not just operation key.
# One foreign invalid amendment cannot poison the owner's accepted edit.
foreign = first.merge('__id' => 35, '__insertion_user' => 'Other', 'amendment_json' => false)
isolated = build.call([first, foreign])
assert_equal('First', publication.call(isolated, 10).fetch('title'))
assert_equal('confirmed', isolated.operation_status(tournament_id: 10, account: 'owner', operation_key: 'first-edit'))
assert_equal('unconfirmed', isolated.operation_status(tournament_id: 10, account: 'other', operation_key: 'first-edit'))
assert_equal(['alice'], members.call(isolated, 12))
malformed = first.merge('__id' => 36, 'operation_key' => 'broken-edit', 'amendment_json' => false)
invalid = build.call([first, malformed])
assert_equal('First', publication.call(invalid, 10).fetch('title'))
assert_equal('unconfirmed', invalid.operation_status(tournament_id: 10, account: 'owner', operation_key: 'broken-edit'))
assert(invalid.to_h.dig('diagnostics', 'registrations').any? { |item| item['code'] == 'invalid_amendment' && item['ids'] == [36] })

# Reordering server rows and mutating caller-owned copies cannot alter a
# retained projection, including its history. A later build is independent.
data = Marshal.load(Marshal.dump([publications, joins + [first, second, late]]))
retained = T::RegistrationProjection.build(announcements: data[0], registrations: data[1], registry: registry, complete: true)
serialized = Marshal.dump([retained.to_h, retained.retention_history(10)])
assert_equal(versions.to_h, T::RegistrationProjection.build(announcements: data[0].reverse,
  registrations: data[1].reverse, registry: registry, complete: true).to_h)
data[0].first['title'].replace('Mutated source')
data[1].last['amendment_json'].replace('{}')
assert_equal(serialized, Marshal.dump([retained.to_h, retained.retention_history(10)]))
assert_raises(FrozenError) { retained.to_h.fetch('announcements').first['title'].replace('Changed') }
assert_equal('Original', publication.call(build.call([]), 10).fetch('title'))

# The larger content signature does not relax the complete-read bound. The
# exact maximum remains a usable single operation, not 4096 fake members.
repeated = Array.new(T::Publication::MAX_ROWS) do |i|
  row.call(i + 1, 'alice', 'one-join', 'join', 'tournament_id' => i.even? ? 10 : 11)
end
bounded = T::RegistrationProjection.build(announcements: publications, registrations: repeated, registry: registry, complete: true)
assert_equal(['alice'], members.call(bounded, 10))
assert_equal(4096, bounded.to_h.fetch('operations').first.fetch('record_ids').size)
assert_equal(1, bounded.retention_history(10).fetch(:events).size)
assert_equal(:row_budget, assert_raises(T::Publication::Incomplete) do
  T::RegistrationProjection.build(announcements: publications, registrations: repeated + [repeated.first.merge('__id' => 5000)], registry: registry, complete: true)
end.code)
puts 'PASS independent registration boundaries: generation conflicts, alias retry, lifecycle, authors, isolation and exact row budget'
