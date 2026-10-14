# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
original = nil
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  original = facade.request_match
  assert_equal(:bound, original[:state])
end
root = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1')
before = Dir.glob(File.join(root, '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
rows = []
[false, true].each_with_index do |with_cause, index|
  cause = with_cause ? ArgumentError.new('Przyczyna błędu konfiguracji czytnika') : nil
  primary = JSON::ParserError.new('Błąd programu w owner_reader po zdrowym odczycie dziennika')
  backtrace = ["czytnik-owner-#{index}.rb:31"]
  primary.set_backtrace(backtrace)
  armed = fired = inside = false
  journal = caught = result = nil
  visits = []; mutations = []
  reader = -> do
    if armed
      armed = false; fired = true
      raise primary, cause: cause
    end
    'WlascicielPlikow'
  end
  trace = TracePoint.new(:call, :return, :c_return) do |point|
    if point.defined_class == T::CoordinationJournal && point.method_id == :read
      journal = point.self
      inside = point.event == :call
      visits << {event: point.event, path: point.path, line: point.lineno}
    end
    if inside && point.event == :c_return && point.method_id == :binread && !fired
      bytes = point.return_value
      assert(bytes.is_a?(String) && JSON.parse(bytes).is_a?(Hash), 'Dodatnia kontrola poprawnych bajtów dziennika')
      armed = true
      visits << {event: 'zdrowy_binread', bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}
    end
    if point.event == :call && [T::LocalFixedTeamCoordinationPort, T::LocalFixedTeamReadinessPort].include?(point.defined_class) && %i[store reserve create_bind].include?(point.method_id)
      mutations << point.method_id
    end
  end
  actor_backend(context, players.first, owner_reader: reader) do |backend, authority, directory|
    window = record['evidence']['plan']['matches'].first['windows'].first
    facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
    facade.native_provider = TournamentFixedTeamNativeService.new
    select_match(facade, record)
    begin
      trace.enable(target_thread: nil)
      result = facade.reconcile
    rescue Exception => error
      caught = error
    ensure
      trace.disable
    end
  end
  locks = Dir.glob(File.join(root, '**', '*.lock')).to_h do |path|
    File.open(path, File::RDWR) { |file| [path, !!file.flock(File::LOCK_EX | File::LOCK_NB)] }
  end
  after = Dir.glob(File.join(root, '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
  row = {with_cause: with_cause, fired: fired, visits: visits, same_primary: caught.equal?(primary),
    same_cause: caught && caught.cause.equal?(cause), expected_backtrace: backtrace,
    actual: caught && {class: caught.class.name, message: caught.message, backtrace: caught.backtrace,
      cause_is_primary: caught.cause.equal?(primary), cause_class: caught.cause&.class&.name},
    result: result, before: before, after: after, locks: locks, mutations: mutations,
    journal_held: journal.instance_variable_get(:@held), journal_mutex: journal.instance_variable_get(:@mutex).locked?,
    target: original[:target].to_h, receipt: JSON.parse(File.binread(File.join(root, 'state.json')))['executions'].values.first['operations']['create_bind']}
  rows << row
  oracle_file("readonly-journal-read-#{index}.json", row)
  assert(fired && visits.any? { |v| v[:event] == 'zdrowy_binread' }, 'Rzeczywista granica read/postguard osiągnięta')
  assert_equal(before, after, 'Reconcile i awaria czytnika nie zmieniają dysku')
  assert_equal([], mutations); assert(locks.values.all?)
end
oracle_file('readonly-journal-read.json', rows)
rows.each do |row|
  assert(row[:same_primary] && row[:same_cause] && row[:actual][:backtrace] == row[:expected_backtrace],
    'RED_FT2A_RO_JOURNAL_READ: poprawny dziennik nie może przeklasyfikować błędu owner_reader na Corrupt')
end
puts 'GREEN: exact primary/cause/backtrace czytnika po zdrowym odczycie dziennika'
