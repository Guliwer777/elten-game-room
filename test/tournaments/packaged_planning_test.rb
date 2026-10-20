# encoding: UTF-8
require_relative '../support/binary_rules_load'
require_relative '../support/tournament_schedule_candidate'
require_relative '../../lib/tournaments/schedule_candidate'
require_relative '../../lib/tournaments/public_text'
require_relative '../support/assertions'
include GameRoomTest::Assertions

# Pure planning from authenticated-shaped server records, not a local drafts
# backend. Production definitions are loaded only through the binary boundary.
fixture = TournamentScheduleCandidateFixture
registry = EltenGameRoom::GAME_REGISTRY
[['three_five_eight', 3, {}], ['chess', 2, {}], ['mahjong', 4, {'variant' => 'hong_kong'}]].each do |id, seats, options|
  game = registry.build(id)
  draft = fixture.draft(game_id: id, players: seats, game_options: game.normalize_options(options))
  row = fixture.announcement(draft: draft)
  names = %w[Charlie Alice Bob Dana]
  projection = fixture.projection(announcements: [row], registrations: fixture.joins(names))
  before = Marshal.dump([row, projection.to_h])
  candidate = GameRoomTournaments::ScheduleCandidate.build(
    projection: projection, publication_ref: fixture.reference,
    backend_identity: 'server:packaged-planning-fixture', observed_at: 200).to_h
  assert_equal(names.map(&:downcase).sort, candidate.fetch('roster'))
  assert_equal(id, candidate.fetch('game_id'))
  assert_equal(draft.fetch('game_options'), candidate.fetch('game_options'))
  assert(!candidate.fetch('matches').empty?, 'No match compositions')
  candidate.fetch('matches').each do |match|
    assert_equal(seats, match.fetch('players').size)
    assert_equal([], match.fetch('players') - candidate.fetch('roster'))
    assert_equal(64, match.fetch('match_id').size)
  end
  assert_equal('observed_candidate', candidate.fetch('state'))
  assert_equal(false, candidate.fetch('dispatch_allowed'), 'Planning authorized match dispatch')
  %w[en pl].each do |language|
    GameRoomTestLocalization.use_language(language)
    text = GameRoomTournaments::PublicText.new(registry: registry,
      mode_label: 'Server-backed tournament', actor: 'Alice').description(row, projection.to_h)
    assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?, 'Invalid packaged rules text')
    assert(text.include?('Test only.'), 'Organizer notes were lost')
    scoring = GameRoomContent.utf8(GameRoomLocalization.translate(GameRoomTournaments::ScoringText::DEFAULT))
    assert_equal(1, text.scan(scoring).size, 'Automatic scoring was omitted or duplicated')
  end
  assert_equal(before, Marshal.dump([row, projection.to_h]), 'Viewing changed source tournament data')
end
puts 'PASS packaged server tournament planning: authenticated roster, multiplayer compositions, Mahjong options, read-only localized rules'
