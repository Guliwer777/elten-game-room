# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
player = record['evidence']['plan']['matches'].first['players'].first['username']
execution_for(context, record, player) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
end
root = File.join(context.directory, 'plany', 'fixed-teams-v1/execution-ft2-v1')
map = -> { Dir.glob(File.join(root, '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] } }
before = map.call
rows = []
[false, true].each_with_index do |with_cause, index|
  cause = with_cause ? ArgumentError.new('Przyczyna awarii czytnika konfiguracji') : nil
  primary = JSON::ParserError.new('Błąd programu owner_reader po zdrowym odczycie gotowości')
  stack = ["owner-readiness-#{index}.rb:19"]
  primary.set_backtrace(stack)
  armed = fired = inside = false
  visits = []; mutations = []; result = caught = nil
  reader = -> do
    if armed
      armed = false; fired = true
      raise primary, cause: cause
    end
    'WlascicielPlikow'
  end
  trace = TracePoint.new(:call, :return, :c_return) do |point|
    if point.defined_class == T::ReadinessJournal && point.method_id == :records
      inside = point.event == :call
      visits << {event: point.event, file: point.path, line: point.lineno}
    end
    if inside && point.event == :c_return && point.method_id == :binread && !fired
      bytes = point.return_value
      assert(bytes.is_a?(String) && JSON.parse(bytes).is_a?(Hash), 'Zdrowy dokument rzeczywiście odczytany')
      armed = true
      visits << {event: 'zdrowy_binread', bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}
    end
    if point.event == :call && ([T::LocalFixedTeamReadinessPort, T::LocalFixedTeamCoordinationPort].include?(point.defined_class) && %i[store reserve create_bind].include?(point.method_id) || point.defined_class == T::ReadinessJournal && point.method_id == :claim)
      mutations << point.method_id
    end
  end
  actor_backend(context, player, owner_reader: reader) do |backend, authority, directory|
    window = record['evidence']['plan']['matches'].first['windows'].first
    facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
    select_match(facade, record)
    begin
      trace.enable(target_thread: nil)
      result = facade.declare(availability: 'ready', expected_revision: 0)
    rescue Exception => error
      caught = error
    ensure
      trace.disable
    end
  end
  locks = Dir.glob(File.join(root, '**', '*.lock')).to_h do |path|
    File.open(path, File::RDWR) { |file| [path, !!file.flock(File::LOCK_EX | File::LOCK_NB)] }
  end
  rows << {with_cause: with_cause, fired: fired, visits: visits, result: result, same_primary: caught.equal?(primary),
    same_cause: caught && caught.cause.equal?(cause), expected_backtrace: stack, actual_backtrace: caught&.backtrace,
    before: before, after: map.call, mutations: mutations, locks: locks,
    actual_error: caught && {class: caught.class.name, message: caught.message}}
  assert(fired && visits.any? { |row| row[:event] == 'zdrowy_binread' })
  assert_equal(before, map.call); assert_equal([], mutations); assert(locks.values.all?)
end
oracle_file('readonly-readiness-records.json', rows)
rows.each do |row|
  assert(row[:same_primary] && row[:same_cause] && row[:actual_backtrace] == row[:expected_backtrace],
    'RED_FT2A_RO_READINESS_RECORDS: błąd programu czytnika nie może stać się journal_corrupt ani wynikiem blocked')
end
puts 'GREEN: exact primary/cause/backtrace po zdrowym odczycie dziennika gotowości'
