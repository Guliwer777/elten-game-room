# encoding: UTF-8
require_relative 'tournament_public_service'
require_relative '../../lib/tournaments/public_service'

module TournamentFixedTeamsSupport
  include GameRoomTest::Assertions
  include TournamentPublicServiceSupport
  T = GameRoomTournaments
  REGISTRY = GameRoomGames::CATALOG
  NAMES = %w[Ala Anna Bartek Beata Celina Cezary].freeze
  TEMPLATE = [0, 1, 0, 1].freeze

  def membership
    {'version' => 1, 'kind' => 'fixed-teams', 'units' => [
      {'unit_id' => 'unit-A', 'accounts' => %w[ala anna]},
      {'unit_id' => 'unit-B', 'accounts' => %w[bartek beata]},
      {'unit_id' => 'unit-C', 'accounts' => %w[celina cezary]}]}
  end

  def fixture(rematch: true, pairing: 'all_combinations', names: NAMES, game: 'spades', directory: nil, group_count: nil, places_per_group: nil, group_advancement: nil, game_options: {}, timezone: 'local_test:system')
    directory ||= Dir.mktmpdir('ft1-', ENV.fetch('TMPDIR'))
    directory = File.expand_path(directory)
    context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator')
    service = context.service
    settings = draft(game).merge('players_per_match' => 4, 'rematch' => rematch, 'pairing' => pairing)
    if group_count || group_advancement
      settings.merge!('format' => 'groups_knockout', 'group_count' => group_count, 'places_per_group' => places_per_group, 'group_advancement' => group_advancement)
    end
    settings['game_options'] = REGISTRY.build(game).normalize_options((game == 'taboo' ? {} : {'team_size' => 2}).merge(game_options))
    settings['windows'] << {'date' => '2026-10-16', 'start' => '12:00', 'end_date' => '2026-10-16', 'end' => '21:00'}
    published = service.publish(**params(game, draft: settings, timezone: timezone))
    assert_equal('confirmed', published['status'], 'Potwierdzona rzeczywista publikacja')
    row = service.list['announcements'].first
    names.each do |name|
      context.actor = name
      joined = context.service(journal: context.reopen_journal).join(tournament_id: row['__id'])
      assert_equal('confirmed', joined['status'], 'Potwierdzony samodzielny join')
    end
    context.actor = 'Organizator'
    context.now = 201
    reference = {'author' => 'Organizator', 'publication_key' => published['values']['publication_key']}
    [context, service, reference]
  end

  def with_backend(context, **changes)
    require_relative 'tournament_entry_context'
    require_relative '../../lib/tournaments/local_fixed_team_plan_backend'
    directory = File.expand_path(File.join(context.directory, 'plany'))
    identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: context.provider.backend_identity)
    program = TournamentEntryContextTest::Program.new(directory)
    session = T::LocalReadinessSession.new
    session.choose_actor('Organizator')
    session.bind_backend(identity)
    reader = changes.delete(:reader) || -> { 'WlascicielPlikow' }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader, account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: reader, entry: entry, lease: entry.capture, actor: 'Organizator', identity: identity)
    build = -> { T::LocalFixedTeamPlanBackend.new(directory: directory, tables: context.provider, journal: context.journal,
      actor: 'Organizator', registry: REGISTRY, clock: -> { context.now }, context: authority, **changes) }
    yield build.call, build, session, authority, directory
  ensure
    authority&.close
    entry&.close
    session&.close
    program&.finalize
    program&.class&.app_runtime&.close
  end

  def bases(source, template = TEMPLATE)
    rows = [%w[beata anna bartek ala], %w[ala cezary anna celina], %w[celina beata cezary bartek]]
    rows = rows.map { |row| [row[0], row[2], row[1], row[3]] } if template == [0, 0, 1, 1]
    source['candidate']['matches'].select { |match| match['leg'] == 1 }.zip(rows).to_h { |match, row| [match['match_id'], row] }
  end

  def oracle_file(name, value)
    return unless ENV['ENTRY_EVIDENCE']
    File.open(File.join(ENV.fetch('ENTRY_EVIDENCE'), name), 'wx:UTF-8') { |file| file.write(JSON.pretty_generate(value)) }
  end
end
