# encoding: UTF-8
require 'json'
require 'tmpdir'
require_relative '../support/assertions'
require_relative '../support/model_contract'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/publication'
require_relative '../../lib/tournaments/registration_projection'
require_relative '../../lib/tournaments/tables_gateway'
require_relative '../../lib/tournaments/local_test_tables'

module TournamentPublicFlowTest
  extend GameRoomTest::Assertions
  module_function

  def fixture(id = 'chess')
    game = GameRoomGames::CATALOG.build(id)
    options = game.default_options
    { 'name' => "Próba #{id}", 'game_id' => id, 'game_options' => options,
      'format' => 'round_robin', 'rematch' => false,
      'players_per_match' => GameRoomTest::ModelContract.players_for(game, options).length,
      'pairing' => 'all_combinations', 'participants' => ['Nie publikuj lokalnego rosteru'],
      'windows' => [{ 'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00' }] }
  end

  def snapshot(game = 'chess', **options)
    GameRoomTournaments::Publication.from_draft(draft: fixture(game), registry: GameRoomGames::CATALOG,
      publication_key: "publication-#{game}", rules: 'Jawny regulamin próby.', registration_opens_at: 100,
      registration_closes_at: 200, timezone: 'Europe/Warsaw', **options)
  end

  def projection(gateway)
    GameRoomTournaments::RegistrationProjection.build(
      announcements: gateway.read_rows('tournament_announcements'),
      registrations: gateway.read_rows('tournament_registrations'),
      registry: GameRoomGames::CATALOG, complete: true)
  end

  def test_persisted_publications_and_joins_for_all_games
    Dir.mktmpdir('tournament-public-flow-', ENV.fetch('TMPDIR')) do |directory|
      actor = 'Testowy Organizator'
      now = 90
      provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor }, clock: -> { now })
      gateway = GameRoomTournaments::TablesGateway.new(server_tables: provider, user: -> { actor }, page_limit: 3)
      announcements = GameRoomGames::CATALOG.ids.map do |id|
        gateway.append('tournament_announcements', snapshot(id).to_row)
      end
      now = 150
      actor = 'Testowa Żaneta'
      announcements.each do |row|
        values = GameRoomTournaments::RegistrationProjection.join_values(tournament_id: row.fetch('__id'),
          operation_key: "join-#{row.fetch('game')}")
        gateway.append('tournament_registrations', values)
      end
      actor = 'Testowy Bartek'
      first = announcements.first
      gateway.append('tournament_registrations', GameRoomTournaments::RegistrationProjection.join_values(
        tournament_id: first.fetch('__id'), operation_key: 'join-bartek'))
      # Ponowne otwarcie pliku, nie pamięciowa atrapa magazynu.
      reopened = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor }, clock: -> { now })
      again = GameRoomTournaments::TablesGateway.new(server_tables: reopened, user: -> { actor }, page_limit: 2)
      result = projection(again).to_h
      assert_equal(32, result.fetch('announcements').length)
      assert_equal(33, result.fetch('members').length)
      assert_equal([], result.fetch('diagnostics').fetch('announcements'))
      assert_equal([], result.fetch('diagnostics').fetch('registrations'))
      assert_equal(32, result.fetch('members').count { |row| row.fetch('account') == 'testowa żaneta' })
      assert_equal(first.fetch('__id'), result.fetch('members').find { |row| row.fetch('account') == 'testowy bartek' }.fetch('tournament_id'))
    end
  end

  def test_valid_nested_json_rejects_duplicate_keys
    row = snapshot.to_row.merge('__id' => 1, '__insertion_user' => 'Testowy Organizator', '__insertion_time' => 90)
    %w[settings_json schedule_json].each do |field|
      valid_json = row.fetch(field)
      key = field == 'settings_json' ? 'rematch' : 'windows'
      # Po pominięciu duplikatu pozostałby w pełni poprawny dokument.
      duplicate = valid_json.sub('{', "{\"#{key}\":null,")
      report = GameRoomTournaments::Publication.project(rows: [row.merge(field => duplicate)],
        registry: GameRoomGames::CATALOG, complete: true)
      assert_equal([], report.fetch('announcements'), "Duplikat #{field} został przyjęty jako poprawne ogłoszenie")
      assert(!report.fetch('diagnostics').empty?)
    end
  end

  def test_uncertain_local_commit_is_exposed_by_gateway
    Dir.mktmpdir('tournament-public-uncertain-', ENV.fetch('TMPDIR')) do |directory|
      actor = 'Testowy Organizator'
      provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor }, clock: -> { 90 })
      gateway = local_gateway(provider, user: -> { actor })
      original = provider.method(:insert_row)
      calls = 0
      provider.define_singleton_method(:insert_row) do |name, values|
        calls += 1
        original.call(name, values)
        # Odpowiednik awarii po skutecznym rename: dane zapisane, brak potwierdzenia.
        raise GameRoomTournaments::LocalTestTables::Error, :store_io_error
      end
      error = assert_raises(GameRoomTournaments::TablesGateway::UnconfirmedWrite) do
        gateway.append('tournament_announcements', snapshot.to_row)
      end
      assert_equal(1, calls)
      assert_equal(snapshot.to_row, error.values)
      assert_equal(actor, error.account)
      assert_equal('tournament_announcements', error.table_name)
      assert_equal(nil, error.attempted_id)
      assert_equal(GameRoomTournaments::TablesGateway::ProviderFailure, error.cause.class)
      assert_equal(:store_io_error, error.cause.cause.code)
      assert_raises(FrozenError) { error.values['title'].clear }
      assert_raises(FrozenError) { error.account.clear }
      assert_equal(1, gateway.read_rows('tournament_announcements').length)
      assert_equal(1, projection(gateway).to_h.fetch('announcements').length)
    end
  end

  def local_gateway(provider, user:, **options)
    GameRoomTournaments::TablesGateway.new(server_tables: provider, user: user,
      operation_error_classes: [GameRoomTournaments::LocalTestTables::Error], **options)
  end

  def test_local_read_failure_is_provider_failure_with_original_cause
    Dir.mktmpdir('tournament-public-read-failure-', ENV.fetch('TMPDIR')) do |directory|
      provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { 'Testowy Aktor' })
      gateway = local_gateway(provider, user: -> { 'Testowy Aktor' })
      path = File.join(directory, GameRoomTournaments::LocalTestTables::FILE_NAME)
      File.binwrite(path, '{')
      error = assert_raises(GameRoomTournaments::TablesGateway::ProviderFailure) do
        gateway.read_rows('tournament_announcements')
      end
      assert_equal(GameRoomTournaments::LocalTestTables::Error, error.cause.class)
      assert_equal(:corrupt_store, error.cause.code)
      assert_equal('{', File.binread(path))
    end
  end

  def test_local_context_loss_after_real_write_is_unconfirmed_without_retry
    [:account, :cancelled].product([false, true]).each do |change, response_lost|
      Dir.mktmpdir('tournament-public-context-', ENV.fetch('TMPDIR')) do |directory|
        actor, cancelled = 'Testowy Organizator', false
        provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor }, clock: -> { 90 })
        gateway = local_gateway(provider, user: -> { actor }, cancelled: -> { cancelled })
        original = provider.method(:insert_row)
        calls = 0
        provider.define_singleton_method(:insert_row) do |name, values|
          calls += 1
          row = original.call(name, values)
          change == :account ? actor = nil : cancelled = true
          raise GameRoomTournaments::LocalTestTables::Error, :store_io_error if response_lost
          row
        end
        error = assert_raises(GameRoomTournaments::TablesGateway::UnconfirmedWrite) do
          gateway.append('tournament_announcements', snapshot.to_row)
        end
        reason = change == :account ? GameRoomTournaments::TablesGateway::ContextChanged : GameRoomTournaments::TablesGateway::Cancelled
        assert_equal(reason, error.cause.class)
        assert_equal(:store_io_error, error.cause.cause.code) if response_lost
        assert_equal('Testowy Organizator', error.account)
        assert_equal(snapshot.to_row, error.values)
        actor, cancelled = 'Testowy Organizator', false
        assert_equal(1, gateway.read_rows('tournament_announcements').length)
        assert_equal(1, calls)
      end
    end
  end

  def test_local_preflight_does_not_insert_or_claim_uncertain_write
    [:account, :cancelled, :fetch_error].each do |change|
      Dir.mktmpdir('tournament-public-preflight-', ENV.fetch('TMPDIR')) do |directory|
        actor, cancelled = 'Testowy Organizator', false
        provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor })
        gateway = local_gateway(provider, user: -> { actor }, cancelled: -> { cancelled })
        original = provider.method(:fetch)
        provider.define_singleton_method(:fetch) do |name|
          raise GameRoomTournaments::LocalTestTables::Error, :store_io_error if change == :fetch_error
          table = original.call(name)
          change == :account ? actor = nil : cancelled = true
          table
        end
        calls = 0
        provider.define_singleton_method(:insert_row) { |*_args| calls += 1; raise 'Nie wolno wysłać' }
        reason = case change
        when :account then GameRoomTournaments::TablesGateway::ContextChanged
        when :cancelled then GameRoomTournaments::TablesGateway::Cancelled
        else GameRoomTournaments::TablesGateway::ProviderFailure
        end
        error = assert_raises(reason) { gateway.append('tournament_announcements', snapshot.to_row) }
        assert_equal(:store_io_error, error.cause.code) if change == :fetch_error
        assert_equal(0, calls)
        assert(!File.exist?(File.join(directory, GameRoomTournaments::LocalTestTables::FILE_NAME)))
      end
    end
  end

  def test_actor_boundary_persists_and_remains_in_projection
    ['x', 'x' * 64, '😀' * 64].each do |actor|
      Dir.mktmpdir('tournament-public-actor-', ENV.fetch('TMPDIR')) do |directory|
        provider = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor }, clock: -> { 150 })
        gateway = local_gateway(provider, user: -> { actor })
        row = gateway.append('tournament_announcements', snapshot.to_row)
        gateway.append('tournament_registrations', GameRoomTournaments::RegistrationProjection.join_values(
          tournament_id: row.fetch('__id'), operation_key: 'actor-boundary'))
        again = GameRoomTournaments::LocalTestTables.new(directory: directory, user: -> { actor })
        result = projection(local_gateway(again, user: -> { actor })).to_h
        assert_equal(1, result['announcements'].length)
        assert_equal([actor], result['members'].map { |member| member['username'] })
        assert_equal([], result['diagnostics']['announcements'])
        assert_equal([], result['diagnostics']['registrations'])
      end
    end
  end

  def run
    selected = ENV['TOURNAMENT_FLOW_TEST']
    methods(false).grep(/^test_/).sort.each do |name|
      next if selected && !name.to_s.include?(selected)
      public_send(name)
      puts "PASS #{name}"
    end
  end
end

TournamentPublicFlowTest.run
