require_relative "../run"
require 'tmpdir'
require 'stringio'

def assert(value, message)
  raise message unless value
end

Dir.mktmpdir('game-room-runner-output-') do |folder|
  descendant = File.join(folder, 'descendant.rb')
  # A completion marker precedes process exit. Do not leave the temporary
  # directory locked as the child's cwd during final teardown on Windows.
  File.write(descendant, "Dir.chdir(#{GameRoomTestRunner::ROOT.inspect})\nsleep 4\nFile.write(ARGV.fetch(0), 'finished')\n")
  run = lambda do |name, source, timeout|
    File.write(File.join(folder, name), source)
    GameRoomTestRunner.run([name], root: folder, timeout: timeout, output: StringIO.new).fetch(0)
  end
  result = run.call('large.rb', 'STDOUT.write("x" * 600_000); puts "final marker"', 3)
  assert(result[:outcome] == 'passed' && result[:output] == 'x' * 600_000 + "final marker\n",
    "Normal output was truncated or reordered: #{result[:outcome]}, #{result[:output].bytesize} bytes, tail #{result[:output][-20..].inspect}")

  # Allow Windows process startup to complete even on a busy CI worker. The
  # sleeping body still cannot finish before the enforced process timeout.
  result = run.call('timeout.rb', '$stdout.sync = true; puts "before timeout"; sleep 60', 1)
  assert(result[:outcome] == 'timeout' && result[:output].include?('before timeout'),
    'A killed process lost already written output')

  [false, true].each do |parent_exits|
    done = File.join(folder, "finished-#{parent_exits}")
    source = <<~RUBY
      require 'rbconfig'
      $stdout.sync = true
      Process.spawn(RbConfig.ruby, #{descendant.inspect}, #{done.inspect}, out: $stdout, err: $stderr)
      puts 'parent output preserved'
      #{'sleep 60' unless parent_exits}
    RUBY
    begin
      result = run.call('inherited.rb', source, 1)
      assert(result[:seconds] < 2.5, 'Inherited output pipe defeated the timeout')
      assert(result[:outcome] == 'timeout', 'Unclosed inherited output was reported as success')
      assert(result[:output].include?('parent output preserved'), 'Partial output was discarded')
    ensure
      # Only our finite descendant; it exits by itself, no PID-based blanket kill.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6
      sleep 0.01 until File.exist?(done) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      assert(File.exist?(done), 'Owned finite descendant did not finish')
    end
  end

  done = File.join(folder, 'finished-redirected')
  begin
    source = "require 'rbconfig'; Process.spawn(RbConfig.ruby, #{descendant.inspect}, #{done.inspect}, out: File::NULL, err: File::NULL); puts 'redirected'"
    result = run.call('redirected.rb', source, 3)
    assert(result[:outcome] == 'passed' && result[:output] == "redirected\n",
      'A descendant without inherited output blocked its completed parent')
  ensure
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6
    sleep 0.01 until File.exist?(done) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert(File.exist?(done), 'Redirected finite descendant did not finish')
  end

  original_threads = Thread.list
  begin
    GameRoomTestRunner.run([{script: 'large.rb', ruby_args: ["\0"]}], root: folder, output: StringIO.new)
    raise 'Invalid process argument was accepted'
  rescue ArgumentError => error
    assert(error.message.include?('null byte'), 'Unexpected launch error')
  end
  assert((Thread.list - original_threads).none?(&:alive?), 'Failed launch leaked a reader')
end
puts 'Runner output: complete logs, partial timeout logs and bounded inherited pipes passed'
