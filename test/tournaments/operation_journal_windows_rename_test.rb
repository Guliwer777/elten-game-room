# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_operation_journal'
require_relative '../../lib/tournaments/operation_journal'

if File::ALT_SEPARATOR == '\\'
  require 'fiddle/import'
  module OperationJournalWindowsReader
    extend Fiddle::Importer
    dlload 'kernel32.dll'
    extern 'void* CreateFileW(void*, unsigned long, unsigned long, void*, unsigned long, unsigned long, void*)'
    extern 'int CloseHandle(void*)'
  end
end

class OperationJournalWindowsRenameTest
  include TournamentOperationJournalProcesses

  def assert(value, message = 'Assertion failed')
    raise message unless value
  end

  def equal(expected, actual)
    assert(expected.eql?(actual), "Expected #{expected.inspect}, got #{actual.inspect}")
  end

  def with_reader(path)
    wide = GameRoomTournaments::LocalFilesystem.native(path).tr('/', '\\').encode('UTF-16LE').b + "\0\0".b
    handle = OperationJournalWindowsReader.CreateFileW(wide, 0x80000000, 3, nil, 3, 0x80, nil)
    assert(handle.to_i != 0 && handle.to_i != -1, 'Cannot open native reader denying FILE_SHARE_DELETE')
    released = false
    release = proc do
      unless released
        assert(OperationJournalWindowsReader.CloseHandle(handle) != 0, 'Cannot close native reader')
        released = true
      end
    end
    yield release
  ensure
    release.call if release
  end

  # Observe real I/O; only the explicit after-commit case injects an exception.
  def trace_write(on_denied: nil, after_commit: nil)
    trace = {rename: 0, write: 0, flush: 0, fsync: 0, locks: []}
    original_open, original_rename = File.method(:open), File.method(:rename)
    File.define_singleton_method(:open) do |path, *args, &block|
      original_open.call(path, *args) do |file|
        names = path.end_with?('.lock') ? [:flock] : [:write, :flush, :fsync]
        names.each do |name|
          original = file.method(name)
          file.define_singleton_method(name) do |*values|
            name == :flock ? trace[:locks] << values.first : trace[name] += 1
            original.call(*values)
          end
        end
        block.call(file)
      end
    end
    File.define_singleton_method(:rename) do |*args|
      trace[:rename] += 1
      begin
        value = original_rename.call(*args)
      rescue Errno::EACCES
        on_denied.call if on_denied
        raise
      end
      after_commit.call if after_commit
      value
    end
    yield trace
  ensure
    File.define_singleton_method(:open, original_open)
    File.define_singleton_method(:rename, original_rename)
  end

  def check_write(trace, renames)
    equal(renames, trace[:rename])
    [:write, :flush, :fsync].each { |name| equal(1, trace[name]) }
    equal([File::LOCK_EX, File::LOCK_UN], trace[:locks])
    assert(Dir.children(@directory).none? { |name| name.include?('.tmp') }, 'Owned temporary leaked')
  end

  def denied
    yield
    raise 'Unsuccessful rename claimed success'
  rescue GameRoomTournaments::OperationJournal::Error => error
    equal(:journal_io_error, error.code)
    assert(error.cause.is_a?(Errno::EACCES), 'Wrong underlying error')
  end

  def run
    GameRoomTest::TemporaryDirectory.create('tournament-operation-journal-rename-') do |directory|
      @directory = directory.tr('\\', '/')
      store = GameRoomTournaments::OperationJournal.new(directory: @directory,
        owner: 'Żaneta', backend_identity: 'local_test:D:/test/baza.json')
      values = {'kind'=>'join', 'operation_key'=>'one', 'tournament_id'=>17}
      if File::ALT_SEPARATOR == '\\'
        first = store.prepare(kind: 'join', intent_id: 'transient', values: values)
        with_reader(store.path) do |release|
          trace_write(on_denied: release) do |trace|
            equal('attempted', store.claim(first['id'])['status'])
            check_write(trace, 2)
          end
        end
        # Distinct real processes must both see the one already-consumed claim.
        workers([['claim', first['id']], ['claim', first['id']]]) do |children|
          equal([nil, nil], release_workers(children))
        end
        blocked = store.prepare(kind: 'join', intent_id: 'persistent', values: values)
        bytes = File.binread(store.path)
        with_reader(store.path) do
          trace_write do |trace|
            denied { store.claim(blocked['id']) }
            check_write(trace, 5)
          end
          equal(bytes, File.binread(store.path))
        end
        equal('prepared', store.fetch(blocked['id'])['status'])
        puts 'PASS native Windows transient reader, bounded permanent refusal, durable lock and one write/fsync'
      else
        puts 'Native Windows sharing scenarios are not applicable on this platform'
      end
      final = store.prepare(kind: 'join', intent_id: 'after-commit', values: values)
      trace_write(after_commit: proc { raise Errno::EACCES, 'lost return after committed rename' }) do |trace|
        denied { store.claim(final['id']) }
        check_write(trace, 1)
      end
      equal('attempted', store.fetch(final['id'])['status'])
      equal(nil, store.claim(final['id']))
      puts 'PASS post-commit permission failure remains uncertain and cannot repeat a claim'
    end
  end
end

OperationJournalWindowsRenameTest.new.run
