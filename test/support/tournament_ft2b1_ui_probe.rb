# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'

module TournamentFT2B1UI
  extend GameRoomTest::Assertions
  F = TournamentFT2B1
  T = F::T
  module_function

  def fixture(directory, count: 2)
    program = TournamentEntryContextTest::Program.new(directory)
    sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(F::OWNER.downcase))
    actor, now = 'Organizator', 150
    tables = T::LocalTestTables.new(directory: File.join(sandbox, 'tables'), user: -> { actor }, clock: -> { now })
    journal = -> { T::OperationJournal.new(directory: File.join(sandbox, 'journals'), owner: actor, backend_identity: tables.backend_identity) }
    gateway = T::TablesGateway.new(server_tables: tables, user: -> { actor }, operation_error_classes: [T::LocalTestTables::Error])
    service = -> { T::PublicService.new(gateway: gateway, journal: journal.call, registry: F::REGISTRY, user: -> { actor }, backend_identity: tables.backend_identity, clock: -> { now }) }
    publications = count.times.map do |index|
      draft = {'name' => "Ekipy #{index}", 'game_id' => 'spades', 'game_options' => F::REGISTRY.build('spades').normalize_options({'team_size' => 2}),
        'format' => 'round_robin', 'rematch' => true, 'players_per_match' => 4, 'pairing' => 'all_combinations', 'participants' => [],
        'windows' => [{'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '16:00'},
          {'date' => '2026-10-15', 'start' => '17:00', 'end_date' => '2026-10-15', 'end' => '21:00'}]}
      result = service.call.publish(draft: draft, intent_id: "publikacja-u-#{index}", rules: 'Jawna próba lokalna.', registration_opens_at: 100, registration_closes_at: 200, timezone: 'local_test:system')
      assert_equal('confirmed', result['status'])
      result
    end
    service.call.list['announcements'].each do |row|
      F::NAMES.each do |name|
        actor = name
        assert_equal('confirmed', service.call.join(tournament_id: row['__id'])['status'])
      end
    end
    actor, now = 'Organizator', 201
    membership = {'version' => 1, 'kind' => 'fixed-teams', 'units' => [
      {'unit_id' => 'unit-A', 'accounts' => %w[ala anna]}, {'unit_id' => 'unit-B', 'accounts' => %w[bartek beata]}, {'unit_id' => 'unit-C', 'accounts' => %w[celina cezary]}]}
    plans = File.join(sandbox, 'plans')
    identity = T::LocalFixedTeamPlanBackend.identity(directory: plans, source_identity: tables.backend_identity)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor); session.bind_backend(identity)
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { F::OWNER }, account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: -> { F::OWNER }, entry: entry, lease: entry.capture, actor: actor, identity: identity)
    begin
      backend = T::LocalFixedTeamPlanBackend.new(directory: plans, tables: tables, journal: journal.call, actor: actor, registry: F::REGISTRY, clock: -> { now }, context: authority)
      records = publications.each_with_index.map do |published, index|
        reference = {'author' => actor, 'publication_key' => published['values']['publication_key']}
        template = [0, 1, 0, 1]
        source = service.call.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: template)
        rows = [%w[beata anna bartek ala], %w[ala cezary anna celina], %w[celina beata cezary bartek]]
        bases = source['candidate']['matches'].select { |m| m['leg'] == 1 }.zip(rows).to_h { |m, r| [m['match_id'], r] }
        options = {publication_ref: reference, membership: membership, team_template: template, base_seats: bases}
        record = backend.accept(preview: backend.preview(**options, intent_id: "plan-u-#{index}"))
        assert_equal(record, backend.accept(preview: backend.preview(**options, intent_id: "alias-u-#{index}")))
        record
      end
      records.each { |record| assert_equal(record, backend.current(intent_id: record['preview']['intent_id'])) }
    ensure
      authority.close; entry.close; session.close
    end
    {program: program, record: records.first, records: records, sandbox: sandbox, plans: plans,
      plan_file: File.join(plans, 'fixed-teams-v1', 'sandbox-k02.json'), now: records.first['evidence']['plan']['matches'].first['windows'].first['opens'] + 60}
  end

  def screen(hub)
    hub.instance_variable_get(:@fixed_team_entry)
  end

  def complete(hub, form)
    2.times do
      work = screen(hub).instance_variable_get(:@readiness_work)
      wait_background_work(work) if work && work.busy?
      form.update
    end
  end

  def enter(driver, actor = 'Ala')
    F.actor(driver, actor)
    driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
  end

  def leave(driver)
    driver.step('Accepted fixed-team plans', [27])
    driver.step('Local tournament tests', [27])
  end

  def evidence(name, value)
    File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), name + '.json'), JSON.pretty_generate(value))
  end

  def snapshot(directory)
    Dir.glob(File.join(directory, '**', '*')).select { |p| File.file?(p) && !p.end_with?('.lock') }.to_h do |p|
      [p.delete_prefix(directory + '/'), File.binread(p).unpack1('H*')]
    end
  end
end
