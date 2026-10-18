# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/assertions'
require 'tmpdir'
require_relative '../../lib/tournaments/local_execution_plan_storage'
include GameRoomTest::Assertions
T = GameRoomTournaments

['C:niebezpieczne', '//serwer/udzial', "zly\nfolder"].each do |directory|
  error = assert_raises(T::Publication::Invalid) { T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {}) }
  assert_equal(:invalid_directory, error.code, 'Odmowa ścieżki przed I/O')
end
puts 'PASS odrzucenie niebezpiecznych ścieżek'

GameRoomTest::TemporaryDirectory.create('k02-storage-limit-') do |directory|
  directory = File.expand_path(directory)
  storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {})
  validator = ->(doc) { assert(doc.is_a?(Hash), 'Magazyn wymaga obiektu') }
  legal = {'version' => 1, 'identity' => 'test', 'records' => [], 'intents' => []}
  storage.access(validate: validator) { storage.write(legal) }
  original = File.binread(storage.path)
  oversized = {'tekst' => "\u0001" * (T::LocalExecutionPlanStorage::MAX_BYTES / 4)}
  assert(JSON.generate(oversized).bytesize > T::LocalExecutionPlanStorage::MAX_BYTES, 'Fixture przekracza budżet po escapowaniu')
  error = assert_raises(T::Publication::Invalid) { storage.access(validate: validator) { storage.write(oversized) } }
  assert_equal(:sandbox_limit, error.code)
  assert(original == File.binread(storage.path), 'Odrzucony zapis nie zmienia dokumentu')
  File.binwrite(storage.path, ' ' * (T::LocalExecutionPlanStorage::MAX_BYTES + 1))
  error = assert_raises(T::Publication::Invalid) { storage.access(validate: validator) { raise 'Nie wolno zwrócić nadmiernego dokumentu' } }
  assert_equal(:sandbox_limit, error.code)
  File.binwrite(storage.path, original)
  legal_bytes = File.binread(storage.path)
  ['"version":1,"version":1', '"version":1,"\\u0076ersion":2'].each do |duplicate|
    corrupted = legal_bytes.sub('"version":1', duplicate)
    assert(corrupted != legal_bytes, 'Duplikat rzeczywiście w legalnym dokumencie')
    File.binwrite(storage.path, corrupted)
    assert_raises(T::Publication::Invalid) { storage.access(validate: validator) { raise 'Duplikat został przyjęty' } }
    assert(corrupted == File.binread(storage.path))
  end
end
puts 'PASS budżet całego magazynu z JSON escape oraz StrictJson na legalnym dokumencie'

GameRoomTest::TemporaryDirectory.create('k02-path-guard-') do |directory|
  directory = File.expand_path(directory)
  storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {})
  Dir.mkdir(storage.path)
  error = assert_raises(T::Publication::Invalid) { storage.access(validate: ->(_) {}) { raise 'Niebezpieczny cel został otwarty' } }
  assert_equal(:unsafe_sandbox, error.code)
  Dir.rmdir(storage.path)
  original = File.join(directory, 'oryginal.json')
  File.binwrite(original, '{}')
  File.link(original, storage.path)
  error = assert_raises(T::Publication::Invalid) { storage.access(validate: ->(_) {}) { raise 'Hardlink został przyjęty' } }
  assert_equal(:unsafe_sandbox, error.code)
  assert_equal('{}', File.binread(original))
end
puts 'PASS kontrola typu i hardlinków własnego celu'

[:exception, :throw].each do |mode|
  GameRoomTest::TemporaryDirectory.create('k02-primary-') do |directory|
    directory = File.expand_path(directory)
    cause = ArgumentError.new('Przyczyna testowa')
    primary = Exception.new('Pierwotna awaria flush')
    primary.set_backtrace(['pierwotna-granica:7'])
    handles = []
    open_original, delete_original = File.method(:open), File.method(:delete)
    File.define_singleton_method(:open) do |path, *args, &block|
      file = open_original.call(path, *args)
      if path.start_with?(directory)
        handles << file
        file.define_singleton_method(:flush) { raise primary, cause: cause } if path.include?('.tmp-')
      end
      if block
        begin
          block.call(file)
        ensure
          file.close unless file.closed?
        end
      else
        file
      end
    end
    File.define_singleton_method(:delete) do |path, *args|
      result = delete_original.call(path, *args)
      if path.start_with?(directory) && path.include?('.tmp-')
        mode == :throw ? throw(:wtorny_cleanup, :zly_sukces) : raise(Exception, 'Wtórna awaria cleanup')
      end
      result
    end
    begin
      storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {})
      outcome = catch(:wtorny_cleanup) do
        assert_raises(Exception) { storage.access(validate: ->(_) {}) { storage.write({'wartosc' => 1}) } }
      end
      assert(outcome.equal?(primary), 'Cleanup musi zachować dokładny primary również wobec Exception/throw')
      assert(outcome.cause.equal?(cause) && outcome.backtrace == ['pierwotna-granica:7'], 'Nie zmieniać cause/backtrace')
      assert(handles.all?(&:closed?), 'Własne pliki i lock muszą być zamknięte')
      assert_equal(:before_replace, storage.last_write_state)
      assert(!File.exist?(storage.path), 'Błąd przed rename nie tworzy dokumentu')
    ensure
      File.define_singleton_method(:open, open_original)
      File.define_singleton_method(:delete, delete_original)
    end
    T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {}).access(validate: ->(_) {}) { |doc| assert(doc.nil?) }
  end
end
puts 'PASS zachowanie primary/cause/backtrace oraz zamknięcie uchwytów przy Exception i throw cleanup'

[:lock, :temporary].each do |kind|
  GameRoomTest::TemporaryDirectory.create('k02-preguard-') do |directory|
    directory = File.expand_path(directory)
    handles, effects = [], []
    armed = false
    open_original = File.method(:open)
    File.define_singleton_method(:open) do |path, *args, &block|
      file = open_original.call(path, *args)
      if path.start_with?(directory)
        handles << file
        target = kind == :lock ? path.end_with?('.lock') : path.include?('.tmp-')
        if target
          armed = true
          [:flock, :write].each do |method|
            original = file.method(method)
            file.define_singleton_method(method) { |*values| effects << method; original.call(*values) }
          end
        end
      end
      if block
        begin
          block.call(file)
        ensure
          file.close unless file.closed?
        end
      else
        file
      end
    end
    begin
      storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> { throw(:guard_wyjscie, :przerwano) if armed })
      result = catch(:guard_wyjscie) { storage.access(validate: ->(_) {}) { storage.write({'proba' => 1}) }; :zly_sukces }
      assert_equal(:przerwano, result)
      assert_equal([], effects, 'Guard po przejęciu musi nastąpić PRZED flock/write')
      assert(handles.all?(&:closed?), 'Nielokalny throw preguard nie może pozostawić własnego uchwytu')
      assert(!File.exist?(storage.path))
    ensure
      File.define_singleton_method(:open, open_original)
    end
    T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {}).access(validate: ->(_) {}) { |doc| assert(doc.nil?) }
  end
end
puts 'PASS preguard/throw od pierwszego przejęcia własnego locka i pliku tymczasowego'

GameRoomTest::TemporaryDirectory.create('k02-korzen-') do |directory|
  directory = File.expand_path(directory)
  storage = T::LocalExecutionPlanStorage.new(directory: directory, guard: -> {})
  ['null', 'false', '[]', '1', '"tekst"'].each do |bytes|
    File.binwrite(storage.path, bytes)
    error = assert_raises(T::Publication::Invalid) { storage.access(validate: ->(_) {}) { raise 'Korupcja nie może być pustym magazynem' } }
    assert_equal(:sandbox_corrupt, error.code)
    assert_equal(bytes, File.binread(storage.path))
  end
end
puts 'PASS skalarny dokument nie jest nieistniejącym magazynem'
