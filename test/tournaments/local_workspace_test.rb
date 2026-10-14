# encoding: UTF-8
require_relative '../support/tournament_local_workspace'
source = File.expand_path('../../lib/tournaments/local_workspace.rb', __dir__)
require source if File.file?(source) && ARGV != ['--binary']
Object.class_eval(File.binread(source), source) if ARGV == ['--binary']

module TournamentLocalWorkspaceTest
  extend GameRoomTest::Assertions
  extend TournamentLocalWorkspaceSupport
  T = GameRoomTournaments
  module_function

  def test_01_leniwa_kompozycja_i_pelny_przeplyw_dwoch_aktorow
    assert(defined?(T::LocalWorkspace), 'Brak LocalWorkspace')
    sandbox do |c|
      actor = +'Testowa Alicja'
      w = c.workspace(actor)
      actor.replace('Nie ten aktor')
      assert_equal('Testowa Alicja', w.actor)
      assert(w.actor.frozen?)
      assert_equal('Local test — this computer only', w.mode_label)
      assert_equal(Encoding::UTF_8, w.mode_label.encoding)
      assert_equal('local_test:system', w.timezone)
      assert_equal([], c.path_threads)
      assert_equal([], Dir.children(c.directory))
      input = local_params
      before = Marshal.dump(input)
      published = w.publish(**input)
      assert_equal('confirmed', published['status'])
      assert_equal(before, Marshal.dump(input))
      assert_equal(1, c.path_threads.length)
      assert(c.path_threads.none? { |thread| thread == c.ui_thread })
      assert_equal(1, w.load['announcements'].length)
      other = c.workspace('Testowy Bob')
      assert_equal([], other.operations)
      joined = other.join(1)
      assert_equal('confirmed', joined['status'])
      assert_equal('testowy bob', other.load['members'].first['account'])
      assert_equal('confirmed', other.reconcile(joined['id'])['status'])
      assert_equal([published['id']], w.operations.map { |row| row['id'] })
      restarted = c.workspace('Testowy Bob')
      assert_equal([joined['id']], restarted.operations.map { |row| row['id'] })
      assert_equal(joined['id'], restarted.join(1)['id'])
      files = Dir.glob(File.join(c.directory, '**', '*.json'))
      assert_equal(3, files.length)
      data = JSON.parse(File.binread(c.provider_path))
      assert_equal(1, data['tables']['tournament_registrations']['rows'].length)
      assert(!JSON.generate(data).include?('Nie publikuj rosteru'))
      assert_equal([], c.alerts)
    end
  end
  def test_02_walidacja_i_zmiana_prawdziwego_konta_na_granicach
    sandbox do |c|
      [nil, '', ' Alice', 'Alice ', "Alice\n", 42, "A\u2028B"].each do |invalid|
        assert_raises(T::Publication::Invalid) { c.workspace(invalid) }
        c.user = invalid
        assert_raises(T::Publication::Invalid) { c.workspace }
      end
      assert_equal([], c.path_threads)
      assert_equal([], Dir.children(c.directory))
      c.user = +'RealOwner'
      w = c.workspace
      c.user.replace('REALOWNER')
      assert_equal([], w.operations)
      c.user = 'OtherOwner'
      assert(w.load.nil?, 'Zmiana właściciela musi zwrócić nil')
      assert(c.alerts.last.include?('account changed'))
      c.user = 'RealOwner'
      task_hooks(before: -> { c.user = 'OtherOwner' }) { assert(w.operations.nil?) }
      c.user = 'RealOwner'
      task_hooks(after: -> { c.user = 'OtherOwner' }) { assert(w.load.nil?) }
      c.user = 'RealOwner'
      provider = w.instance_variable_get(:@provider)
      instrument(provider, :select_rows) do |original, *args, **kwargs|
        result = original.call(*args, **kwargs)
        c.user = 'OtherOwner'
        result
      end
      assert(w.load.nil?)
      assert_equal(1, c.path_threads.length)
      assert_equal(1, Dir.children(c.directory).length)
      assert(c.alerts.all? { |text| text.encoding == Encoding::UTF_8 })
    end
  end

  def test_03_guard_wewnatrz_providera_przed_zapisem
    sandbox do |c|
      w = c.workspace
      w.load
      provider = w.instance_variable_get(:@provider)
      instrument(provider, :insert_row) do |original, *args|
        c.user = 'OtherOwner'
        original.call(*args)
      end
      assert(w.publish(**local_params).nil?)
      assert(w.last_error.is_a?(T::TablesGateway::UnconfirmedWrite))
      c.user = 'RealOwner'
      assert(!File.exist?(c.provider_path), 'Provider zapisał mimo zmiany realnego konta')
      assert_equal('attempted', w.operations.first['status'])
    end
  end
  def test_04_snapshot_przed_workerem_i_wymagana_strefa
    sandbox do |c|
      w = c.workspace
      input = local_params
      expected = Marshal.load(Marshal.dump(input))
      task_hooks(before: -> {
        input[:draft]['game_options'].clear
        input[:draft]['name'].replace('Zmiana podczas pompowania UI')
        input[:rules].replace('Zmiana regulaminu')
        input[:intent_id].replace('Zmiana intencji')
        input[:timezone].replace('Europe/Warsaw')
      }) do
        record = w.publish(**input)
        assert_equal(expected[:draft]['name'], record['values']['title'])
        assert_equal(expected[:rules], record['values']['rules'])
        assert_equal(expected[:intent_id], record['intent_id'])
        assert_equal(expected[:draft]['game_options'], JSON.parse(record['values']['settings_json'])['game_options'])
      end
      assert(w.publish(**local_params(timezone: 'Europe/Warsaw')).nil?)
      assert(c.alerts.last.include?('local system time'))
      assert_equal(1, w.operations.length)
    end
  end
  def test_05_zapis_niepewny_restart_i_reconcile_nigdy_nie_wysyla
    [:provider, :read_after_append, :journal_after_append, :service_read_after_append].each do |mode|
      sandbox do |c|
        w = c.workspace
        w.load
        provider = w.instance_variable_get(:@provider)
        journal = w.instance_variable_get(:@journal)
        failure = T::LocalTestTables::Error.new(:store_io_error)
        if mode == :service_read_after_append
          gateway = w.instance_variable_get(:@service).instance_variable_get(:@gateway)
          instrument(gateway, :append) do |original, *args|
            result = original.call(*args)
            instrument(gateway, :read_rows) { |*| raise T::TablesGateway::ProviderFailure, 'Awaria po append' }
            result
          end
        end
        instrument(provider, :insert_row) do |original, *args|
          result = original.call(*args)
          case mode
          when :provider then raise failure
          when :read_after_append
            instrument(provider, :select_rows) { |*| raise failure }
          when :journal_after_append
            instrument(journal, :resolve) { |*| raise T::OperationJournal::Error, :journal_io_error }
          end
          result
        end
        assert(w.publish(**local_params).nil?)
        assert(c.alerts.last.include?('uncertain') && c.alerts.last.include?('do not send again'))
        if mode == :provider
          assert(w.last_error.is_a?(T::TablesGateway::UnconfirmedWrite))
          assert_equal(failure, w.last_error.cause.cause)
        end
        data = JSON.parse(File.binread(c.provider_path))
        assert_equal(1, data['tables']['tournament_announcements']['rows'].length)
        restarted = c.workspace
        operation = restarted.operations.fetch(0)
        assert_equal('attempted', operation['status'])
        assert_equal('confirmed', restarted.reconcile(operation['id'])['status'])
        assert_equal(1, restarted.load['announcements'].length)
        assert_equal(data, JSON.parse(File.binread(c.provider_path)))
      end
    end
  end

  def test_06_bledy_magazynu_i_programu_nie_sa_pusta_lista
    sandbox do |c|
      w = c.workspace
      w.publish(**local_params)
      File.binwrite(c.provider_path, '{uszkodzone')
      assert(w.load.nil?)
      assert(c.alerts.last.include?('damaged'))
      assert_equal('{uszkodzone', File.binread(c.provider_path))
    end
    sandbox do |c|
      w = c.workspace
      w.load
      journal = w.instance_variable_get(:@journal)
      File.binwrite(journal.path, '{uszkodzone')
      assert(w.operations.nil?)
      assert(c.alerts.last.include?('damaged'))
      assert_equal('{uszkodzone', File.binread(journal.path))
    end
    sandbox do |c|
      c.on_path = -> { raise Errno::EACCES, 'Izolowana odmowa dostępu' }
      w = c.workspace
      assert(w.load.nil?)
      assert(c.alerts.last.include?('could not be completed'))
      c.on_path = nil
      c.path = File.join(c.directory, 'nie-przepinaj')
      assert(w.operations.nil?)
      assert_equal(1, c.path_threads.length)
      assert_equal([], Dir.children(c.directory))
    end
    [NoMethodError, ArgumentError].each do |type|
      sandbox do |c|
        w = c.workspace
        w.load
        instrument(w.instance_variable_get(:@provider), :select_rows) { |*| raise type, 'Błąd programu' }
        assert_raises(type) { w.load }
        assert_equal([], c.alerts)
      end
    end
  end

  def test_07_lokalna_odmowa_czasu_bez_serwerowego_potwierdzenia
    sandbox do |c|
      w = c.workspace
      w.publish(**local_params)
      [[99, 'not opened'], [200, 'closed']].each do |now, message|
        c.now = now
        assert(w.join(1).nil?)
        assert(c.alerts.last.include?(message) && c.alerts.last.include?('local computer clock'))
      end
      assert_equal(1, w.operations.length)
      assert(w.join(999).nil?)
      assert(w.reconcile('nie-UUID').nil?)
      assert(w.publish(**local_params(rules: '')).nil?)
    end
  end
  def test_08_pelne_io_na_workerze_i_szkice_nietkniete
    require_relative '../../lib/tournaments/drafts'
    sandbox do |c|
      drafts = T::Drafts.new(c.program, owner: c.user)
      original = drafts.create(draft)
      draft_file = Dir.glob(File.join(c.directory, 'tournament-drafts-*.json')).fetch(0)
      bytes = File.binread(draft_file)
      c.path_threads.clear
      io = []
      calls = %i[open binread binwrite read write lstat stat mkdir mkdir_p rename delete flock fsync flush]
      trace = TracePoint.new(:call, :c_call) do |event|
        if calls.include?(event.method_id) &&
            ([File, Dir, FileUtils].include?(event.self) || event.self.is_a?(File))
          io << [event.method_id, Thread.current]
        end
      end
      begin
        trace.enable
        w = c.workspace
        assert_equal([], io, 'Konstruktor wykonuje I/O')
        record = w.publish(**local_params(draft: original))
        assert_equal('confirmed', record['status'])
        w.load
        w.join(1)
        w.operations
        w.reconcile(record['id'])
      ensure
        trace.disable
      end
      assert(io.any? { |event, _thread| event == :rename })
      assert(io.none? { |_event, thread| thread == c.ui_thread }, 'I/O na wątku UI')
      assert_equal(bytes, File.binread(draft_file))
      assert_equal([original], drafts.list)
    end
  end

  def test_09_inny_owner_izolowany_a_wzgledna_sciezka_stala
    sandbox do |c|
      original_cwd = Dir.pwd
      begin
        Dir.chdir(c.directory)
        c.path = './portable/data'
        w = c.workspace
        assert_equal('confirmed', w.publish(**local_params)['status'])
        saved_path = File.expand_path(c.path)
        other = File.join(c.directory, 'other-cwd')
        FileUtils.mkdir_p(other)
        Dir.chdir(other)
        assert_equal(1, w.load['announcements'].length)
        assert_equal('confirmed', w.join(1)['status'])
        assert_equal([], Dir.children(other))
        assert_equal(1, c.path_threads.length)
        c.path = saved_path
        c.user = 'OtherOwner'
        other_owner = c.workspace
        assert_equal([], other_owner.load['announcements'])
        assert_equal('confirmed', other_owner.publish(**local_params)['status'])
        assert_equal(2, Dir.children(saved_path).length)
      ensure
        Dir.chdir(original_cwd)
      end
    end
  end

  def test_10_zle_sciezki_bez_naprawy_i_zmiana_konta_podczas_kompozycji
    [nil, '', ' ', "bad\0path", 'C:relative', '//server/share'].each do |invalid|
      sandbox do |c|
        c.path = invalid
        w = c.workspace
        assert(w.load.nil?)
        assert_equal([], Dir.children(c.directory))
      end
    end
    sandbox do |c|
      c.on_path = -> { c.user = 'OtherOwner' }
      w = c.workspace
      assert(w.load.nil?)
      c.user = 'RealOwner'
      c.on_path = nil
      c.path = File.join(c.directory, 'inna-sciezka')
      assert(w.operations.nil?)
      assert_equal(1, c.path_threads.length)
      assert_equal([], Dir.children(c.directory))
    end
  end
  def test_11_natywny_portable_w_osobnym_procesie
    require 'open3'
    require 'rbconfig'
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path(__FILE__), '--native-portable')
    assert(status.success?, output)
    assert(output.include?('PASS native portable'))
  end

  def native_portable
    require_relative '../support/host_source'
    bootstrap = EltenTestHost.file('src/bootstrap.rb')
    lines = File.readlines(bootstrap)
    first = lines.index { |line| line.strip == 'module EltenPath' }
    assert(first, 'Brak modułu ścieżek hosta')
    Object.class_eval(lines[first..].join, bootstrap, first + 1)
    require EltenTestHost.file('src/eapi/structs.rb')
    Object.include(EltenAPI)
    require EltenTestHost.file('src/eapi/program.rb')
    sandbox do |c|
      original_cwd = Dir.pwd
      begin
        Dir.chdir(c.directory)
        Dirs.eltendata = './eltendata'
        Dirs.appsdata = EltenPath.join(Dirs.eltendata, 'apps')
        Dirs.apps = EltenPath.join(Dirs.appsdata, 'src')
        runtime = Programs::Runtime.allocate
        runtime.instance_variable_set(:@entry_id, 'tournament-local-workspace-test.eltenapp')
        ::Program.instance_variable_set(:@app_runtime, runtime)
        program = ::Program.allocate
        paths = []
        instrument(program, :data_path) do |original, *args|
          paths << [original.call(*args), Thread.current]
          paths.last.first
        end
        w = c.workspace(program: program)
        assert_equal([], paths)
        record = w.publish(**local_params)
        assert_equal('confirmed', record['status'])
        assert_equal('./eltendata/apps/data/tournament-local-workspace-test', paths.first.first)
        assert(paths.first.last != Thread.current)
        other = File.join(c.directory, 'other-cwd')
        FileUtils.mkdir_p(other)
        Dir.chdir(other)
        assert_equal('confirmed', w.join(1)['status'])
        assert_equal('confirmed', w.reconcile(record['id'])['status'])
        assert_equal(1, w.load['announcements'].length)
        assert_equal(1, paths.length)
        assert_equal([], Dir.children(other))
      ensure
        Dir.chdir(original_cwd)
      end
    end
    puts 'PASS native portable'
  end

  def test_12_zapis_po_zmianie_konta_i_blad_programu_nie_sa_maskowane
    sandbox do |c|
      w = c.workspace
      w.load
      provider = w.instance_variable_get(:@provider)
      instrument(provider, :insert_row) do |original, *args|
        result = original.call(*args)
        c.user = 'OtherOwner'
        result
      end
      assert(w.publish(**local_params).nil?)
      assert(w.last_error.is_a?(T::TablesGateway::UnconfirmedWrite))
      assert(c.alerts.last.include?('uncertain'))
      c.user = 'RealOwner'
      restarted = c.workspace
      operation = restarted.operations.fetch(0)
      assert_equal('confirmed', restarted.reconcile(operation['id'])['status'])
      assert_equal(1, restarted.load['announcements'].length)
    end
    sandbox do |c|
      w = c.workspace
      w.load
      error = NoMethodError.new('Diagnostyka błędu programu')
      instrument(w.instance_variable_get(:@provider), :select_rows) do |*|
        c.user = 'OtherOwner'
        raise error
      end
      assert_equal(error, assert_raises(NoMethodError) { w.load })
      assert_equal([], c.alerts)
    end
    sandbox do |c|
      w = c.workspace
      begin
        raise IOError, 'Starszy wyjątek caller-a'
      rescue IOError
        task_hooks(after: -> { c.user = 'OtherOwner' }) { assert(w.load.nil?) }
      end
      assert(c.alerts.last.include?('account changed'))
    end
  end

  def test_13_kopia_id_przed_workerem_i_komunikat_po_niepewnym_tasku
    sandbox do |c|
      w = c.workspace
      record = w.publish(**local_params)
      id = record['id'].dup
      task_hooks(before: -> { id.replace('nie-UUID') }) do
        assert_equal('confirmed', w.reconcile(id)['status'])
      end
      task_hooks(after: -> { c.user = 'OtherOwner' }) do
        assert(w.publish(**local_params(intent_id: 'inna-intencja')).nil?)
      end
      assert(c.alerts.last.include?('uncertain') && c.alerts.last.include?('account changed'))
    end
  end
  def test_14_reconcile_przygotowanego_zamiaru_bez_insertu
    sandbox do |c|
      w = c.workspace
      w.load
      journal = w.instance_variable_get(:@journal)
      values = publication(timezone: 'local_test:system')
      operation = EltenAPI::Tasks.run(title: 'Test fixture', ui: :none, cancellable: false) do
        journal.prepare(kind: 'publication', intent_id: 'niewyslany', values: values)
      end
      provider = w.instance_variable_get(:@provider)
      instrument(provider, :insert_row) { |*| raise 'Reconcile nie ma prawa wysyłać' }
      assert_equal('prepared', w.reconcile(operation['id'])['status'])
      assert_equal('prepared', w.operations.first['status'])
      assert_equal([], w.load['announcements'])
      assert(!File.exist?(c.provider_path))
    end
  end
end

if ARGV == ['--native-portable']
  TournamentLocalWorkspaceTest.native_portable
  exit
end

TournamentLocalWorkspaceTest.singleton_methods.grep(/^test_/).sort.each do |name|
  TournamentLocalWorkspaceTest.public_send(name)
  puts "PASS #{name}"
end
