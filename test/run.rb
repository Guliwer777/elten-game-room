#!/usr/bin/env ruby
# One process and result per scenario, shared by every named suite.
require "optparse"
require "json"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "support/suites"

module GameRoomTestRunner
  ROOT = File.expand_path("..", __dir__)
  DEFAULT_TIMEOUT = 180
  OUTPUT_DRAIN_TIMEOUT = 0.5

  def self.expand(entries, root: ROOT)
    Dir.chdir(root) do
      entries.flat_map do |entry|
        specification = entry.is_a?(Hash) ? entry : {script: entry}
        pattern = specification.fetch(:script).tr("\\", "/")
        matches = glob(pattern).sort
        raise ArgumentError, "No tests matched: #{pattern}" if matches.empty?
        matches.map { |script| specification.merge(script: script) }
      end.uniq
    end
  end

  def self.glob(pattern)
    return [pattern] if File.file?(pattern)
    if File.directory?(pattern)
      return Dir.glob('**/*_test.rb', base: pattern).sort.select do |path|
        GameRoomTestSuites.automatic_path?(File.join(pattern, path))
      end.map { |path| File.join(pattern, path) }
    end
    return Dir.glob(pattern) unless pattern.match?(%r{\A(?:[A-Za-z]:/|/)})

    # Windows restricted tokens can open a known directory but cannot traverse
    # every ancestor of an absolute glob. Start at its literal directory.
    wildcard = pattern.index(/[*?\[{]/) || pattern.length
    slash = pattern.rindex('/', wildcard)
    directory = slash.zero? ? '/' : pattern[0...slash]
    Dir.glob(pattern[(slash + 1)..], base: directory).map { |path| File.join(directory, path) }
  end

  def self.run(entries, timeout: DEFAULT_TIMEOUT, report: nil, root: ROOT, output: $stdout)
    raise ArgumentError, "Timeout must be positive" unless timeout.positive?
    scripts = expand(entries, root: root)
    raise ArgumentError, "No tests found" if scripts.empty?
    results = []
    scripts.each_with_index do |entry, index|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      captured, timed_out, status = +"".b, false, nil
      command = [entry.fetch(:env, {}), RbConfig.ruby, *entry.fetch(:ruby_args, []),
        entry.fetch(:script), *entry.fetch(:args, [])]
      Open3.popen2e(*command, chdir: root) do |input, stream, waiter|
        input.close
        reader = Thread.new do
          begin
            loop { captured << stream.readpartial(16_384) }
          rescue EOFError
            nil
          end
        end
        unless waiter.join(timeout)
          timed_out = true
          # Only the owned test process, never ELTEN or another Ruby instance.
          Process.kill("KILL", waiter.pid) rescue Errno::ESRCH
          waiter.join
        end
        status = waiter.value
        # A descendant can retain stdout even after the scenario has exited.
        # Never let that pipe defeat the process timeout, and keep partial logs.
        unless reader.join(OUTPUT_DRAIN_TIMEOUT)
          timed_out = true
          reader.kill.join
          captured << "\nTest output did not close after the process exited.\n"
        end
        reader.value
      ensure
        reader&.kill&.join if reader&.alive?
      end
      captured = captured.encode("UTF-8", invalid: :replace, undef: :replace)
      # readpartial preserves CRLF on Windows; match the former text-mode read.
      captured = captured.gsub("\r\n", "\n") if File::ALT_SEPARATOR == "\\"
      outcome = timed_out ? "timeout" : !status.success? ? "failed" : captured.match?(/^\s*SKIP\b/) ? "skipped" : "passed"
      result = {test: entry.fetch(:script), outcome: outcome,
        seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
        exit_status: status.exitstatus, output: captured}
      results << result
      output.puts "[#{index + 1}/#{scripts.length}] #{outcome}: #{result[:test]} (#{result[:seconds]}s)"
      output.puts captured unless outcome == "passed"
      output.flush
      if report
        FileUtils.mkdir_p(File.dirname(report))
        File.write(report, JSON.pretty_generate(results) + "\n")
      end
    end
    results
  end

  def self.success?(results, allow_skip: false)
    results.all? { |item| item[:outcome] == "passed" || (allow_skip && item[:outcome] == "skipped") }
  end

  def self.summary(results, output: $stdout)
    counts = results.group_by { |item| item[:outcome] }.transform_values(&:length)
    output.puts counts.map { |outcome, count| "#{outcome}: #{count}" }.join(", ")
  end

  def self.cli(argv = ARGV)
    args = argv.dup
    options = {timeout: DEFAULT_TIMEOUT, report: nil, allow_skip: false, list: false}
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby test/run.rb [options] [test/games/spades | test/path_test.rb ...]"
      parser.on("--timeout SECONDS", Float) { |value| options[:timeout] = value }
      parser.on("--report PATH") { |value| options[:report] = File.expand_path(value) }
      parser.on("--allow-skip", "Report missing optional dependencies without failing") { options[:allow_skip] = true }
      parser.on("--list", "List the selected scripts without executing them") { options[:list] = true }
      parser.on("--suite NAME", "Select a layer: #{GameRoomTestSuites::NAMES.join(', ')}") { |value| options[:suite] = value }
    end.parse!(args)
    if options[:suite]
      raise ArgumentError, '--suite cannot be combined with script paths' unless args.empty?
      entries = GameRoomTestSuites.select(options[:suite])
    else
      entries = args.empty? ? GameRoomTestSuites.paths : args
    end
    if options[:list]
      expand(entries).each do |entry|
        args_str = entry[:args] && !entry[:args].empty? ? " [#{entry[:args].join(' ')}]" : ""
        puts "#{entry.fetch(:script)}#{args_str}"
      end
      return 0
    end
    results = run(entries, timeout: options[:timeout], report: options[:report])
    summary(results)
    success?(results, allow_skip: options[:allow_skip]) ? 0 : 1
  rescue ArgumentError, OptionParser::ParseError => error
    warn error.message
    1
  end
end

exit GameRoomTestRunner.cli if $PROGRAM_NAME == __FILE__
