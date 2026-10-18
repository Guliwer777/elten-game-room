# encoding: UTF-8
require 'timeout'
require_relative '../support/tournament_moves_fixture'
include GameRoomTest::Assertions
F = TournamentFT2B1
fixture = TournamentMovesFixture.build
record = fixture[:record]
children = []
begin
  revision = nil
  F.with_execution(fixture, 'Beata') do |execution|
    F.select_execution(execution, record)
    revision = execution.local_game(action: :local_game_status)[:status]['revision']
  end
  directory = File.dirname(fixture[:sandbox])
  gate = File.join(directory, 'move-race-gate')
  script = File.expand_path('../support/tournament_move_race_probe.rb', __dir__)
  %w[race-a race-b].each do |id|
    output = File.join(directory, id + '.json')
    pid = Process.spawn(RbConfig.ruby, '-EUTF-8', script, directory, fixture[:now].to_s, revision, id, gate, out: output, err: [:child, :out])
    children << [pid, output]
  end
  Timeout.timeout(30) do
    sleep(0.01) until %w[race-a race-b].all? { |id| File.exist?(gate + '.' + id) }
  end
  File.write(gate, 'go')
  results = children.map do |pid, path|
    status = Timeout.timeout(30) { Process.wait2(pid).last }
    output = File.read(path)
    assert(status.success?, output)
    JSON.parse(output)
  end
  assert_equal(1, results.count { |r| r['state'] == 'confirmed' })
  assert_equal(1, results.count { |r| r['state'] == 'blocked' && r['reason'] == 'stale_view' })
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record)
    assert_equal(1, execution.local_game(action: :local_game_status)[:status]['event_count'])
  end
  # Ordinary read-only transactions cannot append a game_action at all.
  path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  state = JSON.parse(File.read(path))
  tx = F::T::LocalFixedTeamNativeProvider.new.open(state: state['native'], owner: 'Beata')
  begin
    packet = state['native']['cores'].first['entries'].last['packet']
    begin
      tx.program.live_sessions.sessions.first.stack_push(packet, message_id: 'ungranted-move')
      raise 'Read-only local view accepted a move'
    rescue F::T::CoordinationContract::Blocked => error
      assert_equal(:local_create_only, error.code)
    end
  ensure
    tx.close
  end
  puts 'PASS move race: two fresh processes, one deal, stale loser; ungranted endpoint write rejected'
ensure
  primary_error = $!
  cleanup_errors = []
  File.write(gate, 'cleanup') if gate && !File.exist?(gate)
  children.each do |pid, _path|
    begin
      # Only a still-owned, unreaped child may be stopped. A timed-out wait
      # must not be followed by an unbounded wait in cleanup.
      next if Process.waitpid(pid, Process::WNOHANG)
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        # The owned child exited between the nonblocking check and the signal.
      end
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Errno::ECHILD
      # Already reaped by the normal wait2 path; never signal a reused PID.
    rescue StandardError => error
      cleanup_errors << error
      warn "Owned child #{pid} cleanup failed: #{error.class}: #{error.message}"
    end
  end
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
  raise cleanup_errors.first if !primary_error && !cleanup_errors.empty?
end
