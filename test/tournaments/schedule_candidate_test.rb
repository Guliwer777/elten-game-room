# encoding: UTF-8
require_relative '../support/assertions'
require_relative '../support/tournament_schedule_candidate'
source = File.expand_path('../../lib/tournaments/schedule_candidate.rb', __dir__)
require source if File.file?(source)

module ScheduleCandidateTest
  extend GameRoomTest::Assertions
  F = TournamentScheduleCandidateFixture
  T = GameRoomTournaments
  @passed = 0
  def self.test(name)
    yield
    @passed += 1
    puts JSON.generate({ 'pass' => name, 'count' => @passed }, ascii_only: true)
  end

  def self.invalid(code, **changes)
    error = assert_raises(T::ScheduleCandidate::Invalid) { F.build(**changes) }
    assert_equal(code, error.code)
  end
end

include GameRoomTest::Assertions
F = TournamentScheduleCandidateFixture
T = GameRoomTournaments
S = ScheduleCandidateTest

S.test('Publication -> RegistrationProjection -> ScheduleCandidate: 3-5-8, not draft roster') do
  assert(defined?(T::ScheduleCandidate), 'Missing production ScheduleCandidate')
  result = F.build.to_h
  assert_equal(%w[alice bob charlie dana], result.fetch('roster'))
  expected = T::LeaguePlan.build(participants: result.fetch('roster'), players_per_match: 3,
    pairing: 'balanced_cycle', rematch: true)
  assert_equal(8, expected.length)
  assert_equal(expected, result.fetch('matches').map { |m| m.slice('number', 'players', 'leg') })
  assert_equal('observed_candidate', result.fetch('state'))
  assert_equal('unknown', result.fetch('finality'))
  %w[dispatch_allowed finalize_allowed start_allowed].each { |key| assert_equal(false, result.fetch(key)) }
  assert_equal('three_five_eight', result.fetch('game_id'))
  assert_equal(F.draft.fetch('game_options'), result.fetch('game_options'))
  assert_equal(F.draft.fetch('windows'), result.fetch('windows'))
  assert_equal(200, result.fetch('observed_at'))
end

S.test('lower publication alias and reordered duplicate rows preserve schedule identity') do
  row = F.announcement
  first = F.build.to_h
  alias_row = row.merge('__id' => 10, '__insertion_user' => 'TEST ORGANIZER')
  changed = F.projection(announcements: [alias_row, row, row], registrations: F.joins.reverse + F.joins)
  assert_equal(10, changed.to_h.fetch('announcements').first.fetch('__id'))
  after = F.build(projection: changed).to_h
  assert(first.fetch('schedule_id').match?(/\A[0-9a-f]{64}\z/))
  assert_equal(first, after)
end

S.test('new earlier evidence for the same account preserves roster generation') do
  first = F.build.to_h
  view = F.projection(registrations: [F.join(8, 'ALICE', time: 110), *F.joins])
  member = view.to_h.fetch('members').find { |m| m.fetch('account') == 'alice' }
  assert_equal(8, member.fetch('registration_id'))
  after = F.build(projection: view).to_h
  assert(first.fetch('roster_generation').match?(/\A[0-9a-f]{64}\z/))
  assert_equal(first, after)
end

S.test('late-visible eligible join creates new generation and disjoint match identities') do
  first = F.build.to_h
  before = Marshal.dump(first)
  view = F.projection(registrations: [*F.joins, F.join(9, 'Eve', time: 199)])
  after = F.build(projection: view, observed_at: 300).to_h
  assert_equal(%w[alice bob charlie dana eve], after.fetch('roster'))
  assert(first.fetch('roster_generation') != after.fetch('roster_generation'))
  assert(first.fetch('schedule_id') != after.fetch('schedule_id'))
  ids = first.fetch('matches').map { |m| m.fetch('match_id') }
  later_ids = after.fetch('matches').map { |m| m.fetch('match_id') }
  assert_equal(ids.length, ids.uniq.length)
  assert_equal([], ids & later_ids)
  first.fetch('matches').each do |match|
    expected = Digest::SHA256.hexdigest(JSON.generate(['tournament-match-v1', first.fetch('schedule_id'),
      match.fetch('players'), match.fetch('leg')]))
    assert_equal(expected, match.fetch('match_id'))
  end
  assert_equal(before, Marshal.dump(first))
  assert_equal('unknown', after.fetch('finality'))
  assert_equal(false, after.fetch('dispatch_allowed'))
end

S.test('incomplete or corrupt snapshots cannot become a healthy smaller schedule') do
  [false, nil, 1, 'true'].each do |complete|
    error = assert_raises(T::Publication::Incomplete) { F.projection(complete: complete) }
    assert_equal(:incomplete_snapshot, error.code)
  end
  bad_rows = [nil, F.join(1, 'Intruder'), F.join(20, 'Alice', key: 'join-1', tournament: 999),
    F.join(20, 'Alice', key: 'join-1').merge('__insertion_time' => nil),
    F.join(20, 'Outside', time: 201).merge('__insertion_time' => '201')]
  bad_rows.each do |bad|
    view = F.projection(registrations: [*F.joins, bad])
    assert(!view.to_h.fetch('diagnostics').fetch('registrations').empty?)
    S.invalid(:unresolved_source_diagnostics, projection: view)
  end
  row = F.announcement
  [row.merge('__id' => 10, 'rules' => 'Conflicting terms'),
    row.merge('__id' => 10, 'settings_json' => '{'), nil].each do |bad|
    S.invalid(:unresolved_source_diagnostics, projection: F.projection(announcements: [row, bad]))
  end
end

S.test('healthy outside-window joins are excluded; confirmed retry may have rejected evidence') do
  first = F.build.to_h
  outside = [F.join(50, 'Excluded', time: 99), F.join(51, 'Too Late', time: 200),
    F.join(52, 'Alice', time: 201, key: 'join-2')]
  view = F.projection(registrations: [*F.joins, *outside])
  assert_equal(3, view.to_h.fetch('diagnostics').fetch('registrations').length)
  assert_equal(first, F.build(projection: view).to_h)
  # A malformed alias is not excused by another, healthy outside-window row.
  bad = F.join(53, 'Alice', time: 201, key: 'join-2').merge('kind' => 'withdraw')
  S.invalid(:unresolved_source_diagnostics, projection: F.projection(registrations: [*F.joins, *outside, bad]))
end

S.test('observed UTC closure is necessary but never gives finality or dispatch permission') do
  [0, 99, 100, 199].each { |now| S.invalid(:registration_open, observed_at: now) }
  [200, 201, T::Publication::MAX_INTEGER].each do |now|
    result = F.build(observed_at: now).to_h
    assert_equal(F.build.to_h.fetch('schedule_id'), result.fetch('schedule_id'))
    assert_equal('unknown', result.fetch('finality'))
    %w[dispatch_allowed finalize_allowed start_allowed].each { |key| assert_equal(false, result.fetch(key)) }
  end
  assert_raises(ArgumentError) { F.build(trust: true) }
end

S.test('requires an actual checked projection, not a hash or duck-typed substitute') do
  fake = Object.new
  def fake.to_h; raise 'Must not read a pretender'; end
  def fake.is_a?(_type); true; end
  [nil, {}, F.projection.to_h, fake, T::RegistrationProjection.allocate,
    T::RegistrationProjection.allocate.freeze].each do |value|
    S.invalid(:invalid_projection, projection: value)
  end
end

S.test('observed time is integer UTC in range, without coercion') do
  hostile = Object.new
  def hostile.to_i; raise 'No coercion'; end
  [nil, true, false, '200', 200.0, Rational(200), -1, 2**63, hostile].each do |time|
    S.invalid(:invalid_observed_at, observed_at: time)
  end
end

S.test('backend identity and exact publication reference are bounded typed data') do
  [nil, 1, 1.0, true, {}, [], '', 'x' * 4097, "x\ny", "\xFF".b,
    'abc'.encode('UTF-16LE')].each { |value| S.invalid(:invalid_backend_identity, backend_identity: value) }
  bad_refs = [nil, 30, 30.0, '30', [], {}, F.reference.merge('id' => 30),
    { author: 'test organizer', publication_key: 'fixture-schedule' }]
  [nil, 1, 1.0, '', ' test organizer', 'A' * 65, "\xFF".b].each do |author|
    bad_refs << F.reference.merge('author' => author)
  end
  [nil, 1, 1.0, '', 'x' * 65, 'has spaces', 'Ż'].each do |key|
    bad_refs << F.reference.merge('publication_key' => key)
  end
  bad_refs.each { |ref| S.invalid(:invalid_publication_ref, publication_ref: ref) }
  S.invalid(:missing_publication, publication_ref: F.reference.merge('author' => 'other'))
  S.invalid(:missing_publication, publication_ref: F.reference.merge('publication_key' => 'other'))
  assert_equal(F.build.to_h, F.build(publication_ref: F.reference.merge('author' => 'TEST ORGANIZER')).to_h)
  assert(F.build(backend_identity: 'x' * 4096))
end

S.test('backend, verified author, publication key and full terms isolate identities') do
  first = F.build.to_h
  assert_equal('local_test:fixture-A', first.fetch('backend_identity'))
  assert_equal(F.reference, first.fetch('publication_ref'))
  assert(first.fetch('publication_digest').match?(/\A[0-9a-f]{64}\z/))
  other_backend = F.build(backend_identity: 'local_test:fixture-B').to_h
  assert(first.fetch('schedule_id') != other_backend.fetch('schedule_id'))
  assert_equal([], first.fetch('matches').map { |m| m.fetch('match_id') } &
    other_backend.fetch('matches').map { |m| m.fetch('match_id') })
  [F.announcement(author: 'Other'), F.announcement(key: 'other'),
    F.announcement(rules: 'Other terms.'), F.announcement(timezone: 'UTC'),
    F.announcement(registration_closes_at: 199)].each do |row|
    ref = { 'author' => row.fetch('__insertion_user'), 'publication_key' => row.fetch('publication_key') }
    after = F.build(projection: F.projection(announcements: [row]), publication_ref: ref).to_h
    assert(first.fetch('schedule_id') != after.fetch('schedule_id'))
  end
  rows = [F.announcement, F.announcement(id: 40, author: 'Other')]
  view = F.projection(announcements: rows, registrations: [*F.joins, F.join(20, 'Not Our Member', tournament: 40)])
  assert_equal(first, F.build(projection: view).to_h)
end

S.test('integration payload preserves options windows and choices, never implies assigned roles') do
  draft = F.draft
  first = F.build.to_h
  %w[format pairing rematch players_per_match].each { |key| assert_equal(draft.fetch(key), first.fetch(key)) }
  assert_equal('Europe/Warsaw', first.fetch('timezone'))
  assert_equal(100, first.fetch('registration_opens_at'))
  assert_equal(200, first.fetch('registration_closes_at'))
  assert_equal('unassigned', first.fetch('roles_teams'))
  variants = [draft.merge('rematch' => false), draft.merge('pairing' => 'all_combinations'),
    draft.merge('game_options' => draft.fetch('game_options').merge('bot_delay' => 1)),
    draft.merge('windows' => [draft.fetch('windows').first.merge('start' => '13:00')])]
  variants.each do |value|
    row = F.announcement(draft: value)
    after = F.build(projection: F.projection(announcements: [row])).to_h
    assert(first.fetch('publication_digest') != after.fetch('publication_digest'))
    assert(first.fetch('schedule_id') != after.fetch('schedule_id'))
    assert_equal(value.fetch('game_options'), after.fetch('game_options'))
    assert_equal(value.fetch('windows'), after.fetch('windows'))
  end
  same = F.announcement.merge('private_hand' => ['secret'])
  assert_equal(first, F.build(projection: F.projection(announcements: [same])).to_h)
  assert(!JSON.generate(first).include?('secret'))
end

S.test('cały kandydat jest niezmienny, odłączony od wejść i drugiego wyniku') do
  projection = F.projection
  reference = F.reference
  backend = +'local_test:fixture-A'
  inputs = [projection.to_h, reference, backend]
  before_inputs = Marshal.dump(inputs)
  before_frozen = inputs.flat_map { |v| F.tree_values(v) }.map(&:frozen?)
  candidate = F.build(projection: projection, publication_ref: reference, backend_identity: backend)
  result = candidate.to_h
  other = F.build(projection: projection, publication_ref: reference, backend_identity: backend).to_h
  saved = Marshal.dump(result)
  assert(candidate.frozen?, 'Instancja kandydata musi być zamrożona')
  assert_raises(FrozenError) { candidate.instance_variable_set(:@data, {}) }
  values = F.tree_values(result)
  assert(values.all?(&:frozen?), 'Każda wartość wyniku musi być zamrożona')
  values.each do |value|
    case value
    when Hash
      assert_raises(FrozenError) { value['nadpisanie'] = nil }
      value.keys.each { |key| assert_raises(FrozenError) { key.clear } }
    when Array then assert_raises(FrozenError) { value << 'nadpisanie' }
    when String then assert_raises(FrozenError) { value.replace('nadpisanie') }
    end
  end
  mutable_ids = ->(tree) { F.tree_values(tree).select { |v| [Hash, Array, String].include?(v.class) }.map(&:object_id) }
  assert_equal([], mutable_ids.call(result) & mutable_ids.call(inputs))
  assert_equal([], mutable_ids.call(result) & mutable_ids.call(other))
  assert_equal(before_inputs, Marshal.dump(inputs))
  assert_equal(before_frozen, inputs.flat_map { |v| F.tree_values(v) }.map(&:frozen?))
  reference.fetch('author').clear
  reference.fetch('publication_key').clear
  reference.clear
  backend.clear
  assert_equal(saved, Marshal.dump(candidate.to_h))
  assert_equal(result, other)
  assert_raises(FrozenError) { candidate.to_h.clear }
  assert_equal(saved, Marshal.dump(candidate.to_h))
  # To roundtrip danych, nie restart procesu ani trwały magazyn.
  decoded = JSON.parse(JSON.generate(result))
  assert_equal(result, decoded)
  decoded.fetch('matches').first.fetch('players').first.clear
  assert_equal(saved, Marshal.dump(result))
end

S.test('nieobsługiwane grupy z pucharem nie stają się planem każdy z każdym') do
  row = F.announcement(draft: F.draft(format: 'groups_knockout'))
  projection = F.projection(announcements: [row])
  assert_equal([], projection.to_h.fetch('diagnostics').fetch('announcements'))
  S.invalid(:unsupported_format, projection: projection)
end

S.test('odmowy liczebności i rozmiaru planu zachowują rzeczywistą przyczynę LeaguePlan') do
  cases = [[0, :no_players, :invalid_participants], [1, :too_few_players, :invalid_participants],
    [2, :too_few_players, :invalid_players_per_match], [257, :too_many_players, :invalid_participants],
    [256, :plan_too_large, :too_many_matches]]
  row = F.announcement(draft: F.draft(pairing: 'all_combinations'))
  cases.each do |count, code, cause_code|
    names = Array.new(count) { |i| "Osoba#{i}" }
    projection = F.projection(announcements: [row], registrations: F.joins(names))
    assert_equal(count, projection.to_h.fetch('members').length)
    assert_equal([], projection.to_h.fetch('diagnostics').fetch('registrations'))
    # Granica musi zadziałać przed enumeracją nadmiernego planu.
    guard = TracePoint.new(:c_call) do |event|
      raise 'Rozwinięto nadmierną kombinację' if event.method_id == :combination
    end
    error = guard.enable do
      assert_raises(T::ScheduleCandidate::Invalid) { F.build(projection: projection) }
    end
    assert_equal(code, error.code)
    assert(error.cause.instance_of?(T::LeaguePlan::Invalid))
    assert_equal(cause_code, error.cause.code)
  end
end

S.test('legalne duże pełne kombinacje z rewanżami mieszczą się w kandydacie') do
  [[70, 2, 'chess'], [13, 8, 'poker']].each do |count, seats, game_id|
    names = Array.new(count) { |i| "#{i.to_s.rjust(3, '0')}#{'𐐨' * 61}" }
    draft = F.draft(game_id: game_id, players: seats, pairing: 'all_combinations', rematch: true)
    row = F.announcement(draft: draft)
    projection = F.projection(announcements: [row], registrations: F.joins(names))
    roster = names.map(&:downcase).sort
    expected = T::LeaguePlan.build(participants: roster, players_per_match: seats,
      pairing: 'all_combinations', rematch: true)
    assert(expected.length <= 5000)
    assert(F.tree_values(expected).length > 4096)
    assert(JSON.generate(expected).bytesize > 160_000)
    result = F.build(projection: projection).to_h
    assert_equal(expected, result.fetch('matches').map { |m| m.slice('number', 'players', 'leg') })
    assert_equal(expected.length, result.fetch('matches').map { |m| m.fetch('match_id') }.uniq.length)
    assert_equal(Digest::SHA256.hexdigest(JSON.generate(['tournament-schedule-v1',
      result.fetch('roster_generation'), expected.map { |m| m.values_at('players', 'leg') }])),
      result.fetch('schedule_id'))
    assert_equal(result, F.build(projection: projection).to_h)
    assert(F.tree_values(result).all?(&:frozen?))
    puts JSON.generate({ 'duzy_plan' => { 'osoby' => count, 'stol' => seats,
      'spotkania' => expected.length, 'json_bytes' => JSON.generate(result).bytesize } }, ascii_only: true)
  end
end

module ScheduleCandidateTest
  def self.observed(result)
    assert_equal('observed_candidate', result.fetch('state'))
    assert_equal('unknown', result.fetch('finality'))
    assert_equal('unassigned', result.fetch('roles_teams'))
    permissions = result.select { |key, _| key.end_with?('_allowed') }
    assert_equal(%w[dispatch_allowed finalize_allowed start_allowed], permissions.keys.sort)
    assert(permissions.values.all? { |value| false.equal?(value) })
    result.fetch('matches').each do |match|
      assert_equal(%w[leg match_id number players], match.keys.sort)
    end
  end

  def self.roundtrip(draft, names:, registry: GameRoomGames::CATALOG)
    before = Marshal.dump([draft, names])
    row = F.announcement(draft: draft, registry: registry)
    projection = F.projection(announcements: [row], registrations: F.joins(names), registry: registry)
    assert_equal({ 'announcements' => [], 'registrations' => [] }, projection.to_h.fetch('diagnostics'))
    result = F.build(projection: projection).to_h
    observed(result)
    assert_equal(draft.fetch('game_id'), result.fetch('game_id'))
    assert(draft.fetch('game_options').eql?(result.fetch('game_options')), 'Nie wolno konwertować typów opcji')
    assert_equal(draft.fetch('windows'), result.fetch('windows'))
    assert_equal(names.map(&:downcase).sort, result.fetch('roster'))
    expected = T::LeaguePlan.build(participants: result.fetch('roster'),
      players_per_match: draft.fetch('players_per_match'), pairing: draft.fetch('pairing'), rematch: draft.fetch('rematch'))
    assert_equal(expected, result.fetch('matches').map { |match| match.slice('number', 'players', 'leg') })
    assert_equal(expected.length, result.fetch('matches').map { |match| match.fetch('match_id') }.uniq.length)
    assert_equal(result, F.build(projection: projection).to_h)
    assert_equal(before, Marshal.dump([draft, names]))
    result
  end
end

S.test('rzeczywiste modele: pełny łańcuch dla każdej legalnej liczebności 2..8 wybranego wariantu') do
  coverage = {}
  GameRoomGames::CATALOG.ids.each do |id|
    game = GameRoomGames::CATALOG.build(id)
    # Krowa daily jest jednoosobowa; race to jawny legalny wariant wieloosobowy.
    options = id == 'krowa' ? game.normalize_options('variant' => 'race') : game.default_options
    # Model wybiera legalny wariant; Candidate nie kopiuje jego walidatora.
    sizes = (2..8).select do |size|
      size.between?(game.minimum_players, game.maximum_players) &&
        game.validation_error(options, player_count: size).nil?
    end
    assert(!sizes.empty?, "Brak legalnego wariantu modelu #{id}")
    sizes.product(%w[all_combinations balanced_cycle], [false, true]).each do |seats, pairing, rematch|
      draft = F.draft(game_id: id, players: seats, pairing: pairing, rematch: rematch, game_options: options)
      names = Array.new(seats + 1) { |index| "Osoba#{index}" }.reverse
      S.roundtrip(draft, names: names)
    end
    coverage[id] = sizes
  end
  assert_equal(GameRoomGames::CATALOG.ids.sort, coverage.keys.sort)
  assert_equal((2..8).to_a, coverage.values.flatten.uniq.sort)
  puts JSON.generate({ 'modele_liczebnosci' => coverage,
    'warianty_przeplywu' => coverage.values.sum(&:length) * 4 }, ascii_only: true)
end

S.test('team_seats oraz String i Integer custom unlimited zachowują opcje, nie przypisują osób') do
  [11, 'custom', 'unlimited'].product([true, false], [true, false]).each do |target, arcade, p2p|
    draft = F.draft(game_id: 'axel_pong', players: 4)
    options = draft.fetch('game_options').merge('team_size' => 2, 'team_seats' => [1, 0, 1, 0],
      'target' => target, 'custom_target' => 37, 'arcade' => arcade, 'p2p_enabled' => p2p)
    result = S.roundtrip(draft.merge('game_options' => options), names: %w[Zeta Alfa Gamma Beta Epsilon])
    assert_equal([1, 0, 1, 0], result.fetch('game_options').fetch('team_seats'))
    assert_equal(target.class, result.fetch('game_options').fetch('target').class)
    assert(result.fetch('matches').any? { |match| match.fetch('players') != match.fetch('players').sort })
    assert(!result.key?('team_players'))
  end
end

S.test('otwarty kontrakt opcji przepuszcza legalny Float bez udawania wsparcia katalogu') do
  options = { 'nazwa' => 'Żółw', 'liczba' => 7, 'współczynnik' => 1.25 }
  registry = F.data_registry(options)
  draft = F.draft(game_id: 'chess', players: 2, game_options: options)
  result = S.roundtrip(draft, names: %w[Ala Ola], registry: registry)
  assert_equal(Float, result.fetch('game_options').fetch('współczynnik').class)
  assert_equal(1.25, result.fetch('game_options').fetch('współczynnik'))
  options.fetch('nazwa').clear
  assert_equal('Żółw', result.fetch('game_options').fetch('nazwa'))
end

S.test('przypięte istniejące ID pozostają stałe; uporządkowany skład i leg pozostają w tożsamości') do
  result = F.build.to_h
  assert_equal('0b17d2bf763ce270595c33eba72b83031d685f82580bb1a4061f9b93b13f7f24', result.fetch('roster_generation'))
  assert_equal('0a28499835a200c9e8ec539901cdd9de91e66a17cde6ce847dc02fa1d5a337bc', result.fetch('schedule_id'))
  assert_equal('8205df30fbfdf5da93dc92a31119892fbf94504d19935546b26236ea66e549df', result.fetch('publication_digest'))
  assert_equal(%w[7ced2f5bf4e13ad09a1b2aae95c8d3b420fc07016694aa5cc194c953c7d9805d
    939a389aee8af486274db0a05c91e2c1623a92f1aff9ad728e976073d2908e30
    2bc09c445bace2cbbeae702dc4f1f69d5e1e6ecef298a92fb8dd21fecc2e73d4
    fda9381f793326cb79bd8353bd0eb20f16536f4e6045d1a94cb127c5860b1817
    d24fb0398200ecd4d81899804cfe5b8dcd51005e91152aa733a6d284c6c0bd54
    bf545c1097b2b45fc2fe6cf08e1c90021f4e3d985253b32e9dbdd049a0699d31
    2cf187b6b4a97c17a49bd82f4d40f6f7454015464cf9e5fbd31d0cc94da46242
    81a9b0686db888df0ec6bce286d99e98870ab1e29430d996b261e3183ecfb477],
    result.fetch('matches').map { |match| match.fetch('match_id') })
  result.fetch('matches').each do |match|
    original = ['tournament-match-v1', result.fetch('schedule_id'), match.fetch('players'), match.fetch('leg')]
    assert_equal(Digest::SHA256.hexdigest(JSON.generate(original)), match.fetch('match_id'))
    [original[0..1] + [match.fetch('players').reverse, match.fetch('leg')],
      original[0..2] + [3 - match.fetch('leg')]].each do |changed|
      assert(Digest::SHA256.hexdigest(JSON.generate(changed)) != match.fetch('match_id'))
    end
  end
end

S.test('granice UTF-8 zachowują bajty i odrzucają obce typy bez coercion') do
  author = '𐐨' * 64
  key = 'K' * 64
  row = F.announcement(author: author, key: key)
  names = [author, 'Żaneta', 'Ola']
  projection = F.projection(announcements: [row], registrations: F.joins(names))
  ['𐐨' * 1024, 'x'.b, 'ascii'.encode('US-ASCII'), '\\' * 4096].each do |backend|
    result = F.build(projection: projection, publication_ref: { 'author' => author, 'publication_key' => key },
      backend_identity: backend).to_h
    assert_equal(backend.encode('UTF-8'), result.fetch('backend_identity'))
    assert_equal(Encoding::UTF_8, result.fetch('backend_identity').encoding)
    assert_equal(256, result.fetch('publication_ref').fetch('author').bytesize)
    assert_equal(64, result.fetch('publication_ref').fetch('publication_key').length)
    assert_equal(names.map(&:downcase).sort, result.fetch('roster'))
    S.observed(result)
  end
  ['𐐨' * 1024 + 'a', "a\0b", "a\u2028b", "a\u2029b", "\xC3".b.force_encoding('UTF-8'),
    'Ż'.encode('ISO-8859-2'), :backend, Float::NAN, Float::INFINITY].each do |backend|
    S.invalid(:invalid_backend_identity, backend_identity: backend)
  end
  [Float::NAN, Float::INFINITY, :now].each { |time| S.invalid(:invalid_observed_at, observed_at: time) }
  [author + 'a', "a\u2028b", :author, true].each do |invalid|
    S.invalid(:invalid_publication_ref, publication_ref: F.reference.merge('author' => invalid))
  end
  hostile = Object.new
  def hostile.to_str; raise 'Nie wolno konwertować to_str'; end
  S.invalid(:invalid_backend_identity, backend_identity: hostile)
  S.invalid(:invalid_publication_ref, publication_ref: F.reference.merge('publication_key' => hostile))
end

S.test('głębokość ośmiu poziomów działa w pełnym przepływie, dziewiąty i cykl są odrzucane') do
  options = { 'zagnieżdżenie' => F.nested(6) }
  registry = F.data_registry(options)
  draft = F.draft(game_id: 'chess', players: 2, game_options: options)
  result = S.roundtrip(draft, names: %w[Ala Ola], registry: registry)
  assert_equal(options, result.fetch('game_options'))
  cycle = []; cycle << cycle
  [F.nested(7), cycle].each do |value|
    error = assert_raises(T::Publication::Invalid) do
      F.announcement(draft: draft.merge('game_options' => { 'zagnieżdżenie' => value }), registry: registry)
    end
    assert_equal(:json_budget, error.code)
  end
  row = F.announcement(draft: draft, registry: registry)
  settings = JSON.parse(row.fetch('settings_json'))
  settings['game_options'] = { 'zagnieżdżenie' => F.nested(7) }
  damaged = row.merge('settings_json' => JSON.generate(settings))
  projection = F.projection(announcements: [damaged], registry: registry)
  assert_equal([], projection.to_h.fetch('announcements'))
  assert(projection.to_h.fetch('diagnostics').fetch('announcements').any? { |item| item['code'] == 'invalid_json' })
  S.invalid(:unresolved_source_diagnostics, projection: projection)
end

S.test('wstrzyknięte typy, UTF-8, NaN i głębokość nie omijają rzeczywistej projekcji') do
  good = F.announcement
  cases = [good.merge('settings_json' => []), good.merge('settings_json' => 1.0),
    good.merge('settings_json' => "\xFF".b), good.merge('settings_json' => '{"a":NaN}'),
    good.merge('schedule_json' => JSON.generate('windows' => F.nested(9))),
    good.merge('settings_json' => good.fetch('settings_json').sub('"rematch":true', '"rematch":"true"'))]
  cases.each do |row|
    projection = F.projection(announcements: [row])
    assert_equal([], projection.to_h.fetch('announcements'))
    assert(!projection.to_h.fetch('diagnostics').fetch('announcements').empty?)
    S.invalid(:unresolved_source_diagnostics, projection: projection)
  end
  [nil, true, 1, 1.0, 'A' * 65, "a\u2029b", 'Ż'.encode('ISO-8859-2')].each do |account|
    projection = F.projection(registrations: [*F.joins, F.join(90, account)])
    assert(!projection.to_h.fetch('diagnostics').fetch('registrations').empty?)
    S.invalid(:unresolved_source_diagnostics, projection: projection)
  end
end

S.test('najbliższe granice planu i 256 osób: odmowa następuje przed kombinacjami') do
  [[100, false], [71, true]].each do |count, rematch|
    draft = F.draft(game_id: 'chess', players: 2, pairing: 'all_combinations', rematch: rematch)
    names = Array.new(count) { |i| "Osoba#{i}" }
    result = S.roundtrip(draft, names: names)
    assert_equal(count * (count - 1) / 2 * (rematch ? 2 : 1), result.fetch('matches').length)
    row = F.announcement(draft: draft)
    projection = F.projection(announcements: [row], registrations: F.joins(names + ['Nadmiar']))
    guard = TracePoint.new(:c_call) do |event|
      raise 'Nie wolno rozpocząć kombinacji nadmiernego planu' if event.method_id == :combination
    end
    error = guard.enable { assert_raises(T::ScheduleCandidate::Invalid) { F.build(projection: projection) } }
    assert_equal(:plan_too_large, error.code)
    assert_equal(:too_many_matches, error.cause.code)
    puts JSON.generate({ 'granica_planu' => { 'osoby' => count, 'rewanze' => rematch,
      'spotkania' => result.fetch('matches').length, 'odmowa_osoby' => count + 1 } }, ascii_only: true)
  end
  draft = F.draft(game_id: 'poker', players: 8)
  names = Array.new(256) { |index| "Osoba#{index}" }
  result = S.roundtrip(draft, names: names)
  assert_equal(512, result.fetch('matches').length)
  assert_equal(256, result.fetch('roster').length)
  assert(result.fetch('matches').all? { |match| match.fetch('players').length == 8 })
end

S.test('lokalny bounded_copy ogranicza węzły i głębokość przed serializacją bez zmiany Data') do
  candidate = T::ScheduleCandidate
  # Dowód przed map/JSON.generate: pojedynczy korzeń wystarczy do odmowy tablicy.
  too_many = Array.new(candidate::MAX_RESULT_NODES + 1, 0)
  visits = 0
  guard = TracePoint.new(:call, :c_call) do |event|
    visits += 1 if event.method_id == :visit && event.self.equal?(T::Publication::Data)
    raise 'Nie wolno serializować przekroczonego budżetu' if event.method_id == :generate && event.self.equal?(JSON)
  end
  error = guard.enable do
    assert_raises(T::Publication::Invalid) { candidate.send(:bounded_copy, too_many) }
  end
  assert_equal(:json_budget, error.code)
  assert_equal(1, visits)
  assert_equal(F.nested(8), candidate.send(:bounded_copy, F.nested(8)))
  assert_equal(:json_budget, assert_raises(T::Publication::Invalid) { candidate.send(:bounded_copy, F.nested(9)) }.code)
  assert_equal(:json_budget, assert_raises(T::Publication::Invalid) { T::Publication::Data.copy(Array.new(4096, 0)) }.code)
  assert_equal(:json_budget, assert_raises(T::Publication::Invalid) { T::Publication::Data.copy('x' * 65_536) }.code)
  puts JSON.generate({ 'budzet_kandydata' => { 'wezly' => candidate::MAX_RESULT_NODES,
    'bajty' => candidate::MAX_RESULT_BYTES, 'wizyty_przed_odmowa' => visits } }, ascii_only: true)
end

S.test('błędy programu i nowe odmowy planera zachowują obiekt, backtrace oraz cause') do
  projection = F.projection
  cause = RuntimeError.new('Pierwotna przyczyna')
  errors = [ArgumentError.new('Błąd programu'), NoMethodError.new('Brak metody'), TypeError.new('Zły typ'),
    JSON::NestingError.new('Błąd programu JSON'), T::LeaguePlan::Invalid.new(:unknown_future_code),
    T::LeaguePlan::Invalid.new(:invalid_participants), T::LeaguePlan::Invalid.new(:invalid_players_per_match)]
  errors.each do |original|
    original.set_backtrace(['program.rb:17'])
    F.with_planner(->(**_arguments) { raise original, cause: cause }) do
      returned = assert_raises(original.class) { F.build(projection: projection) }
      assert(returned.equal?(original))
      assert(returned.cause.equal?(cause))
      assert_equal(['program.rb:17'], returned.backtrace)
    end
  end
  original = T::LeaguePlan::Invalid.new(:too_many_matches)
  F.with_planner(->(**_arguments) { raise original, cause: cause }) do
    returned = assert_raises(T::ScheduleCandidate::Invalid) { F.build(projection: projection) }
    assert_equal(:plan_too_large, returned.code)
    assert(returned.cause.equal?(original))
    assert(returned.cause.cause.equal?(cause))
  end
  assert_equal(F.build.to_h, F.build(projection: projection).to_h)
end

S.test('pochodzenie budżetu: maksymalne metadane, okna, nazwa i rekord mieszczą się w stałym oszacowaniu') do
  candidate = T::ScheduleCandidate
  maximum = T::Publication::MAX_INTEGER
  options = { 'tekst' => 'x' * 60_000 }
  registry = F.data_registry(options)
  windows = Array.new(366) do |index|
    date = (Date.new(2026, 1, 1) + index).strftime('%Y-%m-%d')
    { 'date' => date, 'start' => '00:00', 'end_date' => date, 'end' => '23:59' }
  end
  draft = F.draft(game_id: 'chess', players: 2, game_options: options, windows: windows,
    pairing: 'all_combinations').merge('game_id' => 'g' * 32)
  author = '𐐨' * 64
  key = 'k' * 64
  row = F.announcement(draft: draft, registry: registry, author: author, key: key,
    registration_opens_at: maximum - 2, registration_closes_at: maximum - 1, timezone: '\\' * 64)
  joins = F.joins(%w[Ala Ola]).map { |join| join.merge('__insertion_time' => maximum - 2) }
  projection = F.projection(announcements: [row], registrations: joins, registry: registry)
  result = F.build(projection: projection, publication_ref: { 'author' => author, 'publication_key' => key },
    backend_identity: '\\' * 4096, observed_at: maximum).to_h
  S.observed(result)
  assert_equal(options, result.fetch('game_options'))
  assert_equal(windows, result.fetch('windows'))
  context = result.merge(%w[game_options windows roster matches].to_h { |field| [field, nil] })
  context_bytes = JSON.generate(context).bytesize
  windows_bytes = JSON.generate(windows).bytesize
  # Budżet dokumentu okien ma zapas na escapowanie backendu i klucze kontekstu.
  assert(context_bytes > 8192, 'Próba musi obejmować podwojenie ukośników backendu')
  assert(context_bytes + windows_bytes <= 8192 + T::Publication::MAX_JSON_BYTES)
  assert(F.json_nodes(context) <= 64)
  assert(F.json_nodes(windows) <= 4096)
  longest = '𐐨' * 64
  assert_equal(256, longest.bytesize)
  record = { 'number' => 5000, 'players' => Array.new(8, longest), 'leg' => 2, 'match_id' => 'f' * 64 }
  assert_equal(9 + 8, F.json_nodes(record))
  record_bound = candidate::MATCH_FIXED_BYTES + 8 * (256 + 3)
  assert(JSON.generate(record).bytesize + 1 <= record_bound)
  roster_bound = 256 * (256 + 3)
  # Dwa nawiasy rosteru mieszczą się w konserwatywnym kontekście (cztery nil).
  assert(JSON.generate(Array.new(256, longest)).bytesize - 2 <= roster_bound)
  total = context_bytes + windows_bytes + T::Publication::MAX_JSON_BYTES + roster_bound + 5000 * record_bound
  assert(total <= candidate::MAX_RESULT_BYTES)
  puts JSON.generate({ 'dowod_budzetu' => { 'metadane_bajty' => context_bytes, 'okna_bajty' => windows_bytes,
    'metadane_wezly' => F.json_nodes(context), 'okna_wezly' => F.json_nodes(windows),
    'rekord_bajty_z_przecinkiem' => JSON.generate(record).bytesize + 1,
    'rekord_granica' => record_bound, 'oszacowanie_bajty' => total,
    'limit_bajty' => candidate::MAX_RESULT_BYTES } }, ascii_only: true)
end

S.test('surowe nielegalne opcje nie zmieniają się w zdrowego kandydata po normalizacji gry') do
  draft = F.draft(game_id: 'axel_pong', players: 4)
  draft['game_options'].merge!('team_size' => 2, 'team_seats' => [0, 1, 0, 1], 'target' => 'custom', 'custom_target' => 37)
  row = F.announcement(draft: draft)
  S.roundtrip(draft, names: %w[Ala Ola Ela Iza])
  invalids = [{ 'target' => '11' }, { 'target' => 11.0 }, { 'target' => 'nieznany' },
    { 'team_seats' => [0, 1, 0, 1.0] }, { 'team_seats' => [0, 1, 0, '1'] },
    { 'team_seats' => [0, 0, 0, 1] }, { 'arcade' => 'false' }, { 'custom_target' => nil }]
  invalids.each do |change|
    settings = JSON.parse(row.fetch('settings_json'))
    settings.fetch('game_options').merge!(change)
    damaged = row.merge('settings_json' => JSON.generate(settings))
    projection = F.projection(announcements: [damaged])
    assert_equal([], projection.to_h.fetch('announcements'))
    assert(!projection.to_h.fetch('diagnostics').fetch('announcements').empty?)
    S.invalid(:unresolved_source_diagnostics, projection: projection)
  end
end

S.test('Unicode raw 32/33/64: zdrowe potwierdzone konta nie podlegają limitowi długości canonical') do
  draft = F.draft(game_id: 'chess', players: 2, rematch: true)
  row = F.announcement(draft: draft)
  ["\u0130" * 32, "\u0130" * 33, "\u0130" * 64, "\u{10400}" * 64].each do |raw|
    assert_equal(raw, T::Publication::Data.account(raw))
    projection = F.projection(announcements: [row], registrations: F.joins([raw, 'Bob']))
    data = projection.to_h
    assert_equal({ 'announcements' => [], 'registrations' => [] }, data.fetch('diagnostics'))
    assert_equal(2, data.fetch('members').length)
    assert(data.fetch('operations').all? { |operation| operation.fetch('status') == 'confirmed' })
    member = data.fetch('members').find { |item| item.fetch('username') == raw }
    assert_equal(raw.downcase, member.fetch('account'))
    sorted = data.fetch('members').sort_by { |item| item.fetch('account') }
    accounts = sorted.to_h { |item| [item.fetch('username'), item.fetch('account')] }
    expected = T::LeaguePlan.build(participants: sorted.map { |item| item.fetch('username') },
      players_per_match: 2, pairing: draft.fetch('pairing'), rematch: true).map do |match|
      match.merge('players' => match.fetch('players').map { |name| accounts.fetch(name) })
    end
    result = F.build(projection: projection).to_h
    assert_equal(sorted.map { |item| item.fetch('account') }, result.fetch('roster'))
    assert_equal(expected, result.fetch('matches').map { |match| match.slice('number', 'players', 'leg') })
    assert_equal([1, 2], result.fetch('matches').map { |match| match.fetch('leg') })
    S.observed(result)
    puts JSON.generate({ 'unicode_boundary' => { 'raw_characters' => raw.length,
      'raw_bytes' => raw.bytesize, 'canonical_characters' => member.fetch('account').length,
      'canonical_bytes' => member.fetch('account').bytesize, 'matches' => result.fetch('matches').length } }, ascii_only: true)
  end
end

S.test('Unicode raw 65 jest odrzucane przez model, nie naprawiane ani obcinane w Candidate') do
  draft = F.draft(game_id: 'chess', players: 2)
  row = F.announcement(draft: draft)
  ["\u0130" * 65, "\u{10400}" * 65].each do |raw|
    error = assert_raises(T::Publication::Invalid) { T::Publication::Data.account(raw) }
    assert_equal(:invalid_text, error.code)
    rejected = T::Publication.project(rows: [row.merge('__insertion_user' => raw)],
      registry: GameRoomGames::CATALOG, complete: true)
    assert_equal([], rejected.fetch('announcements'))
    assert(rejected.fetch('diagnostics').any? { |item| item.fetch('code') == 'invalid_text' })
    projection = F.projection(announcements: [row], registrations: F.joins(['Bob', raw]))
    assert_equal(['bob'], projection.to_h.fetch('members').map { |item| item.fetch('account') })
    assert(projection.to_h.fetch('diagnostics').fetch('registrations').any? { |item| item.fetch('code') == 'invalid_text' })
    S.invalid(:unresolved_source_diagnostics, projection: projection)
    planner_error = assert_raises(T::LeaguePlan::Invalid) do
      T::LeaguePlan.build(participants: ['Bob', raw], players_per_match: 2,
        pairing: draft.fetch('pairing'), rematch: true)
    end
    assert_equal(:invalid_participants, planner_error.code)
  end
end

S.test('Unicode alias, reroster i wcześniejsze inne spelling tej samej osoby zachowują wszystkie ID i leg/order') do
  raw = "\u0130" * 33 + 'Z'
  alternate = "\u0130" * 32 + "i\u0307z"
  assert(raw != alternate && raw.downcase == alternate.downcase)
  names = [raw, 'Jade', 'ALFA', 'zed']
  %w[balanced_cycle all_combinations].product([false, true]).each do |pairing, rematch|
    draft = F.draft(pairing: pairing, rematch: rematch)
    row = F.announcement(draft: draft)
    joins = F.joins(names)
    projection = F.projection(announcements: [row], registrations: joins)
    before = Marshal.dump(projection.to_h)
    first = F.build(projection: projection).to_h
    ordered = names.sort_by(&:downcase)
    assert(ordered != names.sort, 'Próba musi odróżniać sort raw od sort canonical')
    expected = T::LeaguePlan.build(participants: ordered, players_per_match: 3,
      pairing: pairing, rematch: rematch).map do |match|
      match.merge('players' => match.fetch('players').map(&:downcase))
    end
    assert_equal(expected, first.fetch('matches').map { |match| match.slice('number', 'players', 'leg') })
    if pairing == 'balanced_cycle'
      assert(first.fetch('matches').any? { |match| match.fetch('players') != match.fetch('players').sort })
    end
    replacement_names = [alternate, 'JADE', 'alfa', 'ZED']
    earlier = replacement_names.each_with_index.map { |name, index| F.join(20 + index, name, time: 110) }
    alias_joins = replacement_names.each_with_index.map { |name, index| F.join(40 + index, name, tournament: 10, time: 110) }
    reroster = F.projection(announcements: [row], registrations: F.joins(names.reverse))
    earlier_view = F.projection(announcements: [row], registrations: [*joins, *earlier].reverse)
    alias_view = F.projection(announcements: [row, row.merge('__id' => 10, '__insertion_user' => 'TEST ORGANIZER')],
      registrations: [*alias_joins, *joins].reverse)
    [earlier_view, alias_view].each do |view|
      member = view.to_h.fetch('members').find { |item| item.fetch('account') == raw.downcase }
      assert_equal(alternate, member.fetch('username'))
      assert_equal(110, member.fetch('joined_at'))
    end
    assert_equal(10, alias_view.to_h.fetch('announcements').first.fetch('__id'))
    [reroster, earlier_view, alias_view].each do |view|
      assert_equal({ 'announcements' => [], 'registrations' => [] }, view.to_h.fetch('diagnostics'))
      assert_equal(first, F.build(projection: view).to_h)
    end
    first.fetch('matches').each do |match|
      identity = ['tournament-match-v1', first.fetch('schedule_id'), match.fetch('players'), match.fetch('leg')]
      assert_equal(Digest::SHA256.hexdigest(JSON.generate(identity)), match.fetch('match_id'))
      assert(Digest::SHA256.hexdigest(JSON.generate(identity[0..1] + [match.fetch('players').reverse, match.fetch('leg')])) != match.fetch('match_id'))
      assert(Digest::SHA256.hexdigest(JSON.generate(identity[0..2] + [3 - match.fetch('leg')])) != match.fetch('match_id'))
    end
    assert_equal(before, Marshal.dump(projection.to_h))
    S.observed(first)
  end
end

S.test('Unicode wynik pozostaje immutable/detached z canonical roster, a planer otrzymuje rzeczywiste raw members') do
  names = ["\u0130" * 64, 'Bob']
  row = F.announcement(draft: F.draft(game_id: 'chess', players: 2))
  joins = F.joins(names)
  projection = F.projection(announcements: [row], registrations: joins)
  before = Marshal.dump(projection.to_h)
  expected_raw = projection.to_h.fetch('members').sort_by { |member| member.fetch('account') }
    .map { |member| member.fetch('username') }
  original = T::LeaguePlan.method(:build)
  calls = []
  candidate = F.with_planner(->(**arguments) do
    calls << arguments.fetch(:participants).dup
    original.call(**arguments)
  end) { F.build(projection: projection) }
  assert_equal([expected_raw], calls)
  result = candidate.to_h
  other = F.build(projection: projection).to_h
  assert_equal(names.map(&:downcase).sort, result.fetch('roster'))
  assert(!result.key?('participants'))
  assert(!result.key?('usernames'))
  assert_equal(before, Marshal.dump(projection.to_h))
  assert(candidate.frozen?)
  assert(F.tree_values(result).all?(&:frozen?))
  values = ->(tree) { F.tree_values(tree).select { |item| [Hash, Array, String].include?(item.class) }.map(&:object_id) }
  assert_equal([], values.call(result) & values.call(projection.to_h))
  assert_equal([], values.call(result) & values.call(other))
  assert_raises(FrozenError) { result.fetch('roster').first.clear }
  assert_raises(FrozenError) { result.fetch('matches').first.fetch('players').first.clear }
  saved = Marshal.dump(result)
  names.first.clear
  joins.first.fetch('__insertion_user').replace('Changed')
  assert_equal(saved, Marshal.dump(result))
  assert_equal(other, result)
  S.observed(result)
end
