# encoding: UTF-8
require_relative 'tournament_environment'
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'assertions'
require_relative 'model_contract'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/publication'
require_relative '../../lib/tournaments/registration_projection'
require_relative '../../lib/tournaments/tables_gateway'
require_relative '../../lib/tournaments/local_test_tables'
require_relative '../../lib/tournaments/operation_journal'

module TournamentPublicServiceSupport
  T = GameRoomTournaments
  ANN = 'tournament_announcements'.freeze
  REG = 'tournament_registrations'.freeze

  def draft(id = 'chess')
    game = GameRoomGames::CATALOG.build(id)
    options = game.default_options
    {'name' => "Próba #{id}", 'game_id' => id, 'game_options' => options,
      'format' => 'round_robin', 'rematch' => false,
      'players_per_match' => GameRoomTest::ModelContract.players_for(game, options).length,
      'pairing' => 'all_combinations', 'participants' => ['Nie publikuj rosteru'],
      'windows' => [{'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00'}]}
  end

  def params(id = 'chess', **changes)
    {draft: draft(id), intent_id: "publikacja-#{id}", rules: 'Jawny regulamin próby.',
      registration_opens_at: 100, registration_closes_at: 200, timezone: 'Europe/Warsaw'}.merge(changes)
  end

  def publication(**changes)
    args = params(**changes).reject { |key, _value| key == :intent_id }
    T::Publication.from_draft(**args, registry: GameRoomGames::CATALOG, publication_key: 'ustalony-klucz').to_row
  end

  class Context
    attr_accessor :actor, :now, :insert_time, :available, :after_insert, :before_insert, :before_read, :after_read
    attr_reader :directory, :provider, :gateway, :journal, :inserts, :reads

    def initialize(directory, actor = 'Testowa Żaneta')
      @directory, @actor, @now = directory, actor, 150
      @available, @inserts, @reads = true, [], []
      owner = self
      @provider = T::LocalTestTables.new(directory: File.join(directory, 'tabele'),
        user: -> { @actor }, clock: -> { @insert_time || @now })
      original = @provider.method(:insert_row)
      @provider.define_singleton_method(:insert_row) do |name, values|
        owner.inserts << [name, values]
        owner.before_insert&.call(name, values)
        result = original.call(name, values)
        owner.after_insert&.call(name, values, result)
        result
      end
      @provider.define_singleton_method(:available?) { owner.available && super() }
      @gateway = T::TablesGateway.new(server_tables: @provider, user: -> { @actor }, page_limit: 3,
        operation_error_classes: [T::LocalTestTables::Error])
      read = @gateway.method(:read_rows)
      @gateway.define_singleton_method(:read_rows) do |name, **options|
        owner.reads << name
        owner.before_read&.call(name)
        result = read.call(name, **options)
        owner.after_read&.call(name, result)
        result
      end
      @journal = reopen_journal
    end

    def reopen_journal(backend: @provider.backend_identity, actor: @actor)
      T::OperationJournal.new(directory: File.join(@directory, 'dzienniki'), owner: actor, backend_identity: backend)
    end

    def service(journal: @journal, backend: @provider.backend_identity, **options)
      T::PublicService.new(gateway: @gateway, journal: journal, registry: GameRoomGames::CATALOG,
        user: -> { @actor }, backend_identity: backend, clock: -> { @now }, **options)
    end
  end

  def sandbox
    base = File.expand_path('../../tmp/tournament-public-service-evidence', __dir__)
    FileUtils.mkdir_p(base)
    Dir.mktmpdir('scenariusz-', base) { |directory| yield Context.new(directory) }
  end
end
