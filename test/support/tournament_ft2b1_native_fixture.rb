# encoding: UTF-8
require 'tmpdir'
require_relative 'assertions'
require_relative 'tournament_native'
require_relative 'tournament_entry_context'
require_relative '../../games/spades'
require_relative '../../games/registry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/tournaments/local_fixed_team_plan_backend'

# N: osobny legalny FT1 z jawnym template również w opcjach publikacji.
module TournamentFT2B1NativeFixture
  extend GameRoomTest::Assertions
  T = GameRoomTournaments
  REGISTRY = GameRoomGames::Registry.new([GameRoomGames::Spades])
  OWNER = 'WlascicielPlikow'.freeze
  NAMES = %w[Ala Anna Bartek Beata Celina Cezary].freeze
  ACTION = 'Fixed teams — local execution'.freeze
  module_function

  def field(form, name)
    form.fields.find { |item| item.respond_to?(:header) && item.header == name } || raise("Brak pola #{name}")
  end

  def button(form, name)
    form.fields.grep(Button).find { |item| item.label == name } || raise("Brak przycisku #{name}")
  end

  def actor(driver, name)
    driver.step('Choose a test participant', [13]) do |form|
      field(form, 'Test participant name').set_text(name)
      form.index = form.fields.index(button(form, 'Use test participant'))
    end
  end

  def fixture(directory, template: [0, 1, 0, 1])
    program = TournamentEntryContextTest::Program.new(directory)
    sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(OWNER.downcase))
    actor, now = 'Organizator', 150
    tables = T::LocalTestTables.new(directory: File.join(sandbox, 'tables'), user: -> { actor }, clock: -> { now })
    journal = -> { T::OperationJournal.new(directory: File.join(sandbox, 'journals'), owner: actor, backend_identity: tables.backend_identity) }
    gateway = T::TablesGateway.new(server_tables: tables, user: -> { actor }, operation_error_classes: [T::LocalTestTables::Error])
    service = -> { T::PublicService.new(gateway: gateway, journal: journal.call, registry: REGISTRY, user: -> { actor }, backend_identity: tables.backend_identity, clock: -> { now }) }
    draft = {'name' => 'Stałe ekipy — próba', 'game_id' => 'spades', 'game_options' => REGISTRY.build('spades').normalize_options({'team_size' => 2, 'team_seats' => template}),
      'format' => 'round_robin', 'rematch' => true, 'players_per_match' => 4, 'pairing' => 'all_combinations',
      'participants' => [], 'windows' => [{'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00'}]}
    published = service.call.publish(draft: draft, intent_id: 'publikacja-ft2b1', rules: 'Jawna próba lokalna.', registration_opens_at: 100, registration_closes_at: 200, timezone: 'local_test:system')
    assert_equal('confirmed', published['status'])
    row = service.call.list['announcements'].first
    NAMES.each do |name|
      actor = name
      assert_equal('confirmed', service.call.join(tournament_id: row['__id'])['status'])
    end
    actor, now = 'Organizator', 201
    reference = {'author' => actor, 'publication_key' => published['values']['publication_key']}
    membership = {'version' => 1, 'kind' => 'fixed-teams', 'units' => [
      {'unit_id' => 'unit-A', 'accounts' => %w[ala anna]}, {'unit_id' => 'unit-B', 'accounts' => %w[bartek beata]}, {'unit_id' => 'unit-C', 'accounts' => %w[celina cezary]}]}
    source = service.call.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: template)
    rows = [%w[beata anna bartek ala], %w[ala cezary anna celina], %w[celina beata cezary bartek]]
    rows = rows.map { |r| [r[0], r[2], r[1], r[3]] } if template == [0, 0, 1, 1]
    bases = source['candidate']['matches'].select { |m| m['leg'] == 1 }.zip(rows).to_h { |m, r| [m['match_id'], r] }
    plans = File.join(sandbox, 'plans')
    identity = T::LocalFixedTeamPlanBackend.identity(directory: plans, source_identity: tables.backend_identity)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor); session.bind_backend(identity)
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { OWNER }, account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: -> { OWNER }, entry: entry, lease: entry.capture, actor: actor, identity: identity)
    begin
      backend = T::LocalFixedTeamPlanBackend.new(directory: plans, tables: tables, journal: journal.call, actor: actor, registry: REGISTRY, clock: -> { now }, context: authority)
      preview = backend.preview(publication_ref: reference, membership: membership, team_template: template, base_seats: bases, intent_id: 'plan-ft2b1')
      record = backend.accept(preview: preview)
      assert_equal(record, backend.current(intent_id: 'plan-ft2b1'))
    ensure
      authority.close; entry.close; session.close
    end
    {program: program, record: record, sandbox: sandbox, plans: plans,
      now: record['evidence']['plan']['matches'].first['windows'].first['opens'] + 60}
  end

  def args(fixture)
    {program: fixture.fetch(:program), registry: REGISTRY, user: -> { OWNER },
      alert: ->(message) { raise message }, confirm: ->(*) { raise 'Niezlecone potwierdzenie' }, clock: -> { fixture.fetch(:now) }}
  end
end

module EltenAPI
  def loop_update
    Thread.pass
  end
end
