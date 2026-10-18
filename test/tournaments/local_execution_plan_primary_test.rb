# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport

results = []
[:enoent_pre, :enoent_post, :encoding_pre, :encoding_post].product([false, true]).each do |mode, with_cause|
  name = "#{mode}/cause=#{with_cause}"
  begin
    with_fixture do |f|
      program = TournamentEntryContextTest::Program.new(f.directory)
      session = T::LocalReadinessSession.new
      directory = File.expand_path(File.join(f.directory, 'k02'))
      path = File.join(directory, 'sandbox-k02.json')
      identity = T::LocalExecutionPlanBackend.identity(directory: directory, source_identity: f.tables.backend_identity)
      session.choose_actor(f.actor)
      session.bind_backend(identity)
      armed = fired = stat_done = opened_target = false
      primary = mode.to_s.start_with?('encoding') ? EncodingError.new('Rzeczywisty owner_reader') : Errno::ENOENT.new('Rzeczywisty owner_reader')
      cause = with_cause ? ArgumentError.new('Bezpośrednia przyczyna czytnika') : nil
      backtrace = ['owner-reader-regression:23']
      primary.set_backtrace(backtrace)
      reader = -> do
        names = caller_locations.select { |loc| loc.path.end_with?('/local_execution_plan_storage.rb') }.map(&:base_label)
        target = case mode
        when :enoent_pre then names.include?('path_stat') && !stat_done
        when :enoent_post then names.include?('path_stat') && stat_done
        when :encoding_pre then names.include?('read_document') && names.include?('resource') && !opened_target
        when :encoding_post then names.include?('read_document') && names.include?('resource') && opened_target
        end
        if armed && !fired && target
          fired = true
          raise primary, cause: cause
        end
        f.owner
      end
      entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader, account_events: session.actor_events)
      context = session.context(program: program, owner_reader: reader, entry: entry, lease: entry.capture, actor: f.actor, identity: identity)
      trace = nil
      begin
        backend = T::LocalExecutionPlanBackend.new(directory: directory, tables: f.tables, journal: f.journal, actor: f.actor,
          registry: GameRoomGames::CATALOG, clock: -> { f.now }, context: context)
        shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: name)
        # Istniejący poprawny dokument wymusza rzeczywisty read_document/resource.
        if mode.to_s.start_with?('encoding')
          backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'healthy'))
        else
          FileUtils.mkdir_p(directory)
        end
        before = File.exist?(path) ? File.binread(path) : nil
        writes = []
        handles = []
        trace = TracePoint.new(:call, :c_call, :c_return) do |event|
          if event.event == :c_return && event.method_id == :lstat && event.path.end_with?('/local_execution_plan_storage.rb')
            stat_done = true
          elsif event.event == :c_return && event.method_id == :open
            file = event.return_value
            if file.is_a?(File) && !file.closed? && file.path.start_with?(directory)
              handles << file
              opened_target = true if file.path == path
            end
          elsif event.event == :call && event.defined_class == T::LocalExecutionPlanStorage && event.method_id == :write
            writes << :write
          end
        end
        result = error = nil
        armed = true
        trace.enable(target_thread: nil)
        begin
          result = backend.accept(preview: shown)
        rescue Exception => caught
          error = caught
        ensure
          trace.disable
        end
        after = File.exist?(path) ? File.binread(path) : nil
        assert(fired, 'Dojście do zamierzonej granicy zaufanego czytnika')
        assert(error.equal?(primary), "Ten sam primary zamiast #{error&.class}; wynik=#{!result.nil?}, zapis=#{writes.inspect}")
        assert_equal(primary.class, error.class)
        assert(error.cause.equal?(cause), 'Bezpośredni cause, także nil')
        assert_equal(backtrace, error.backtrace)
        assert_equal(nil, result)
        assert_equal([], writes, 'Błąd czytnika przed przekazaniem dokumentu do mutacji')
        assert_equal(before, after, 'Legalny dokument nie jest nadpisywany')
        assert(handles.all?(&:closed?), 'Wszystkie rzeczywiście przejęte uchwyty zamknięte')
        assert(!handles.empty?, 'Dodatnia kontrola obserwacji plików') if mode.to_s.start_with?('encoding')
        assert(opened_target, 'Próba postguard po przejęciu docelowego pliku') if mode == :encoding_post
        T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {}).access(validate: ->(_) {}) { |_doc| }
        assert_equal(before, File.exist?(path) ? File.binread(path) : nil)
      ensure
        trace&.disable
        context.close
        entry.close
        session.close
        program.finalize
        program.class.app_runtime.close
      end
    end
    puts "PASS #{name}"
    results << {'case' => name, 'passed' => true}
  rescue StandardError => error
    puts "FAIL #{name}: #{error.class}: #{error.message}"
    results << {'case' => name, 'passed' => false, 'error' => error.message, 'backtrace' => error.backtrace}
  end
end

# Brak pliku oraz błędne bajty parsera pozostają odrębnymi przypadkami danych.
GameRoomTest::TemporaryDirectory.create('primary-parser-') do |directory|
  storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {})
  storage.access(validate: ->(_) {}) { |doc| assert_equal(nil, doc); storage.write({'legal' => true}) }
  original = File.binread(storage.path)
  ['{', '{"legal":true,"legal":false}', '{"legal":true,"\\u006cegal":false}', '[]'].each do |bytes|
    File.binwrite(storage.path, bytes)
    error = assert_raises(T::Publication::Invalid) { storage.access(validate: ->(_) {}) { raise 'Parser dopuścił korupcję' } }
    assert_equal(:sandbox_corrupt, error.code)
    assert_equal(bytes, File.binread(storage.path))
  end
  File.binwrite(storage.path, original)
  storage.access(validate: ->(_) {}) { |doc| assert_equal({'legal' => true}, doc) }
end
puts 'PASS real absent/StrictJson/malformed/duplicate/root'
if ENV['ENTRY_EVIDENCE']
  File.binwrite(File.join(ENV['ENTRY_EVIDENCE'], 'primary-test.json'), JSON.pretty_generate(results))
end
raise 'Primary z rzeczywistego owner_reader' unless results.all? { |row| row['passed'] }
