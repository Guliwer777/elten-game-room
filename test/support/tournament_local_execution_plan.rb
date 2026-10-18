# encoding: UTF-8
require_relative 'temporary_directory'
require_relative 'tournament_public_service'
require_relative 'tournament_entry_context'
require_relative '../../lib/tournaments/public_service'
require_relative '../../lib/tournaments/local_readiness_session'
require_relative '../../lib/tournaments/coordination_request'

module TournamentLocalExecutionPlanSupport
  include GameRoomTest::Assertions
  include TournamentPublicServiceSupport
  T = GameRoomTournaments

  class Fixture
    include TournamentLocalExecutionPlanSupport
    attr_reader :directory, :tables, :reference, :journal, :session, :context, :author_service, :registry
    attr_accessor :now, :actor, :owner
    def initialize(directory, names: %w[Beta Alpha], rematch: true, game: 'chess', windows: nil, reopen: false,
      registry: GameRoomGames::CATALOG, players_per_match: nil, game_options: nil, group_count: nil, places_per_group: nil, group_advancement: nil, knockout_rematch: nil, final_rematch: nil, knockout_wins_to:nil,final_wins_to:nil, timezone: 'local_test:system')
      @registry = registry
      @directory, @now, @actor, @owner = directory, 150, 'Organizator', 'WlascicielPlikow'
      @tables = T::LocalTestTables.new(directory: File.join(directory, 'tables'), user: -> { @actor }, clock: -> { @now })
      @journal = journal_for(@actor)
      @author_service = service(@journal)
      if reopen
        row = @author_service.list['announcements'].first
        @reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
        @now = 201
        return
      end
      settings = draft(game).merge('rematch' => rematch)
      if group_count || group_advancement
        settings.merge!('format' => 'groups_knockout', 'group_count' => group_count, 'places_per_group' => places_per_group, 'group_advancement' => group_advancement)
      end
      settings['game_options'] = game_options if game_options
      settings.merge!('knockout_rematch' => knockout_rematch, 'final_rematch' => final_rematch) unless knockout_rematch.nil? && final_rematch.nil?
      settings['knockout_wins_to']=knockout_wins_to if knockout_wins_to
      settings['final_wins_to']=final_wins_to if final_wins_to
      settings['players_per_match'] = players_per_match if players_per_match
      settings['windows'] = windows if windows
      result = @author_service.publish(**params(game, draft: settings, timezone: timezone))
      assert_equal('confirmed', result['status'], 'Rzeczywista publikacja sandboxa')
      row = @author_service.list['announcements'].first
      @reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
      names.each do |actor|
        @actor = actor
        if actor.downcase.length > 64
          # Istniejący journal odmawia rozwiniętego ownera. Źródło nadal może
          # zawierać legalny join tych tabel; nie zmieniamy starego kontraktu.
          tables.fetch('tournament_registrations').insert(T::RegistrationProjection.join_values(tournament_id: row['__id'], operation_key: SecureRandom.uuid))
        else
          assert_equal('confirmed', service(journal_for(actor)).join(tournament_id: row['__id'])['status'], 'Rzeczywisty join sandboxa')
        end
      end
      @actor, @now = 'Organizator', 201
    end
    def draft(id = 'chess')
      return super if @registry.equal?(GameRoomGames::CATALOG)
      game = @registry.build(id)
      options = game.default_options
      super('chess').merge('game_id' => id, 'game_options' => options, 'players_per_match' => game.minimum_players)
    end
    def journal_for(actor)
      T::OperationJournal.new(directory: File.join(directory,'journals'), owner: actor, backend_identity: tables.backend_identity)
    end
    def service(journal)
      gateway = T::TablesGateway.new(server_tables: tables, user: -> { @actor }, operation_error_classes: [T::LocalTestTables::Error])
      T::PublicService.new(gateway: gateway, journal: journal, registry: @registry,
        user: -> { @actor }, backend_identity: tables.backend_identity, clock: -> { @now })
    end
    def base
      @author_service.schedule_candidate(publication_ref: reference).to_h['matches'].select { |m| m['leg'] == 1 }.to_h do |m|
        [m['match_id'], m['players'].reverse]
      end
    end
    def backend(context: :trusted, registry: @registry)
      if context == :trusted
        unless @context
          @program = TournamentEntryContextTest::Program.new(directory)
          @session = T::LocalReadinessSession.new
          @session.choose_actor(@actor)
          identity = T::LocalExecutionPlanBackend.identity(directory: File.join(directory,'k02'), source_identity: tables.backend_identity)
          @session.bind_backend(identity)
          reader = -> { @owner }
          @entry = T::EntryContext.new(program: @program, runtime: @program.class.app_runtime, owner_reader: reader, account_events: @session.actor_events)
          @context = @session.context(program: @program, owner_reader: reader, entry: @entry, lease: @entry.capture, actor: @actor, identity: identity)
        end
        context = @context
      end
      T::LocalExecutionPlanBackend.new(directory: File.join(directory,'k02'), tables: tables,
        journal: journal_for(@actor), actor: @actor, registry: registry, clock: -> { @now }, context: context)
    end
    def close
      @context&.close
      @entry&.close
      @session&.close
      @program&.finalize
      @program&.class&.app_runtime&.close
    end
  end

  def with_fixture(**options)
    directory = GameRoomTest::TemporaryDirectory.create('k02-')
    fixture = Fixture.new(directory, **options)
    begin
      yield fixture
    ensure
      fixture.close
    end
  end

  def request(record, match)
    T::CoordinationRequest.from_execution_plan(evidence: record.fetch('evidence'), expected_source: record.fetch('expected_source'),
      match_id: match.fetch('match_id'), leg: match.fetch('leg'), window_id: match.fetch('windows').first.fetch('id'), registry: GameRoomGames::CATALOG).to_h
  end
end
