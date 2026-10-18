# encoding: UTF-8
require_relative '../support/tournament_evidence_environment'
require_relative '../support/ft2_runtime_cold'
require 'rbconfig'
include FT2RuntimeCold
rows = []
%w[mutation publication].each do |stage|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + '-' + stage)
  all_ready(context, record)
  actor = record['evidence']['plan']['matches'].first['players'].first['username']
  fired = false; child = nil; result = nil; after_child = nil; later = []; trace = nil
  runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
    select_match(facade, record)
    trace = TracePoint.new(:return) do |event|
      next if fired || event.defined_class != T::LocalFixedTeamCoordinationPort
      hit = stage == 'mutation' ? event.method_id == :snapshot && event.return_value['grant'] : event.method_id == :lookup_target
      next unless hit
      fired = true
      files = Dir[File.join(context.directory, '**', '*')].select { |p| File.file?(p) }
      locks, durable = files.partition { |p| p.end_with?('.lock') }
      # Storage zwolnił swoją blokadę; Journal nadal trzyma własny lock próby.
      # Nie otwieramy treści żadnego locka, także pustego.
      lock_metadata = locks.map { |p| {path: p, size: File.size(p), status: 'nieodczytany_uchwyt_lock'} }
      pins = durable.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
      oracle_file("child-#{stage}-locks.json", lock_metadata)
      oracle_file("child-#{stage}-source-prepin.json", {
        source: JSON.parse(File.binread(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'source-before.json'))),
        runtime: JSON.parse(File.binread(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'runtime-before.json'))),
        tools: JSON.parse(File.binread(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'tools-before.json')))})
      pins.each do |p, sha|
        archive = File.join(ENV.fetch('ENTRY_EVIDENCE'), "child-#{stage}-blobs", sha)
        FileUtils.mkdir_p(File.dirname(archive)); File.binwrite(archive, File.binread(p)) unless File.exist?(archive)
      end
      child_file = File.expand_path('../support/ft2_fencing_revoke_process.rb', __dir__)
      oracle_file("child-#{stage}-before.json", {inputs: pins, argv: [RbConfig.ruby, child_file, context.directory, stage], env: TournamentTestEvidence.environment})
      stdout = File.join(ENV.fetch('ENTRY_EVIDENCE'), "child-#{stage}-stdout.raw")
      stderr = File.join(ENV.fetch('ENTRY_EVIDENCE'), "child-#{stage}-stderr.raw")
      pid = Process.spawn(RbConfig.ruby, child_file, context.directory, stage, out: stdout, err: stderr)
      oracle_file("child-#{stage}-pid.json", {pid: pid, parent: Process.pid})
      _, status = Process.wait2(pid)
      child = {pid: pid, exit: status.exitstatus, joined: true}
      oracle_file("child-#{stage}-result.json", child)
      assert_equal(0, status.exitstatus, 'Dziecko musi rzeczywiście zmienić trwałą epokę')
      after_child = File.binread(state_path(context))
    end
    effects do |calls|
      trace.enable(target_thread: nil)
      begin
        # Rzeczywisty worker, a nie wynik atrapy całego Service.
        worker = Thread.new { outcome { facade.request_match } }
        begin
          result = worker.value
        ensure
          worker.join
          oracle_file("worker-#{stage}-join.json", {id: worker.object_id, joined: !worker.alive?})
        end
        assert(!worker.alive?)
      ensure
        trace.disable
      end
      later = calls
    end
    after = File.binread(state_path(context))
    row = {stage: stage, child: child, result: result.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v },
      calls: later, disk_after_child_equal: after_child == after, state: state(context), fired: fired}
    rows << row; oracle_file("fencing-#{stage}.json", row)
    assert(fired && child[:pid] != Process.pid)
    assert_equal(:blocked, result[:state], 'RED_FT2A_RUNTIME_FENCING: nie publikuj bound starej epoki po drugim procesie')
    assert_equal(:stale_coordinator, result[:reason])
    assert(after_child == after, 'Po zmianie epoki zero zapisu przez starego wykonawcę')
    assert_equal(stage == 'mutation' ? 0 : 1, state(context)['native']['creates'].size)
    puts "GREEN: #{stage}, rzeczywisty B i odcięcie starego workera"
  end
end
puts 'GREEN: dwuprocesowe fencing przed mutacją i przed publikacją wyniku'
