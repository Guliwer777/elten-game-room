# encoding: UTF-8
require_relative 'tournament_evidence_environment'
require_relative 'ft2_runtime_cold'
require 'rbconfig'
module FT2FencingProbe
  include FT2RuntimeCold
  def durable_map(context)
    Dir[File.join(context.directory, '**', '*')].select { |p| File.file?(p) && !p.end_with?('.lock') }.to_h do |p|
      [p, Digest::SHA256.file(p).hexdigest]
    end
  end
  def revoke_in_child(context, stage)
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
      child_file = File.expand_path('ft2_fencing_revoke_process.rb', __dir__)
      oracle_file("child-#{stage}-before.json", {inputs: pins, argv: [RbConfig.ruby, child_file, context.directory, stage], env: TournamentTestEvidence.environment})
      stdout = File.join(ENV.fetch('ENTRY_EVIDENCE'), "child-#{stage}-stdout.raw")
      stderr = File.join(ENV.fetch('ENTRY_EVIDENCE'), "child-#{stage}-stderr.raw")
      pid = Process.spawn(RbConfig.ruby, child_file, context.directory, stage, out: stdout, err: stderr)
      oracle_file("child-#{stage}-pid.json", {pid: pid, parent: Process.pid})
      _, status = Process.wait2(pid)
      child = {pid: pid, exit: status.exitstatus, joined: true}
      oracle_file("child-#{stage}-result.json", child)
      assert_equal(0, status.exitstatus, 'Dziecko musi rzeczywiście zmienić trwałą epokę')
    child
  end
  def worker_result(stage)
    worker = Thread.new { yield }
    worker.value
  ensure
    if worker
      worker.join
      oracle_file("worker-#{stage}-join.json", {id: worker.object_id, joined: !worker.alive?})
    end
  end
  def count_effects(calls, after_child:)
    trace = TracePoint.new(:call) do |event|
      next unless after_child.call
      relevant = (event.defined_class == T::LocalFixedTeamExecutionStorage && event.method_id == :write) ||
        (event.defined_class == T::LocalFixedTeamReadinessPort && event.method_id == :store) ||
        (event.defined_class == T::LocalFixedTeamCoordinationPort && %i[reserve create_bind].include?(event.method_id)) ||
        (event.defined_class == GameRoomTransport && %i[create_room start_game invite].include?(event.method_id))
      calls << {class: event.defined_class.name, method: event.method_id} if relevant
    end
    trace.enable(target_thread: nil)
    yield
  ensure
    trace&.disable
  end
end
