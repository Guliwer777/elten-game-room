# encoding: UTF-8
require 'open3'
require 'rbconfig'
require 'timeout'
require 'json'

module TournamentOperationJournalProcesses
  def workers(actions)
    children = []
    Timeout.timeout(30) do
      actions.each do |action, argument|
        children << Open3.popen2e(RbConfig.ruby, File.expand_path(__FILE__), action, @directory,
          'Żaneta', 'local_test:D:/test/baza.json', argument)
      end
      children.each { |_input, output, _waiter| equal("READY\n", output.gets) }
      yield(children)
    end
  ensure
    children.each do |input, output, waiter|
      input.close unless input.closed?
      output.close unless output.closed?
      Process.kill('KILL', waiter.pid) if waiter.alive?
      waiter.join
    end
  end

  def release_workers(children)
    children.each { |input, _output, _waiter| input.puts('go'); input.flush }
    children.map do |_input, output, waiter|
      result = output.read
      assert(waiter.value.success?, result)
      JSON.parse(result)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative '../../lib/tournaments/operation_journal'
  $stdout.sync = true
  $stdout.set_encoding(Encoding::UTF_8)
  action, directory, owner, backend, argument = ARGV
  store = GameRoomTournaments::OperationJournal.new(directory: directory, owner: owner, backend_identity: backend)
  puts 'READY'
  raise 'Brak sygnału startu' unless STDIN.gets
  result = case action
  when 'claim'
    store.claim(argument)
  when 'prepare'
    store.prepare(kind: 'join', intent_id: 'racing-intent',
      values: {'tournament_id' => 17, 'operation_key' => argument, 'kind' => 'join'})
  else
    raise 'Nieznana akcja procesu testowego'
  end
  puts JSON.generate(result)
end
