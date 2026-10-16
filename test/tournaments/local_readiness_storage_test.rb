# frozen_string_literal: true
require_relative '../support/assertions'
require_relative '../../lib/tournaments/local_readiness_storage'
require 'tmpdir'

include GameRoomTest::Assertions
T = GameRoomTournaments

Dir.mktmpdir('k03-storage-lock-') do |directory|
  storage = T::LocalReadinessStorage.new(directory: directory, guard: -> {})
  validate = ->(document) { assert(document.is_a?(Hash)) }
  storage.access(validate: validate) { storage.write('value' => 1) }
  checks = 0
  original = File.method(:lstat)
  File.define_singleton_method(:lstat) do |path|
    if path == storage.path
      checks += 1
      File.open(storage.path + '.lock', File::RDWR) do |probe|
        acquired = probe.flock(File::LOCK_EX | File::LOCK_NB)
        probe.flock(File::LOCK_UN) if acquired
        raise 'Document metadata inspected outside its process lock' if acquired
      end
    end
    original.call(path)
  end
  begin
    assert_equal({'value' => 1}, storage.access(validate: validate) { |document| document })
    storage.access(validate: validate) { storage.write('value' => 2) }
    assert(checks >= 4, 'Check real metadata reads during both read and write access')
  ensure
    File.define_singleton_method(:lstat, original)
  end
  assert_equal({'value' => 2}, storage.access(validate: validate) { |document| document })
end
puts 'PASS document metadata is checked under the process lock for reads and writes'

[:document, :lock].each do |target|
  [:directory, :hardlink].each do |kind|
    Dir.mktmpdir('k03-storage-unsafe-') do |directory|
      storage = T::LocalReadinessStorage.new(directory: directory, guard: -> {})
      path = target == :document ? storage.path : storage.path + '.lock'
      source = File.join(directory, 'untouched.json')
      File.binwrite(source, '{"value":17}')
      kind == :directory ? Dir.mkdir(path) : File.link(source, path)
      error = assert_raises(T::ReadinessContract::Blocked) do
        storage.access(validate: ->(_) {}) { raise 'Unsafe path accepted' }
      end
      assert_equal(:unsafe_sandbox, error.code)
      assert_equal('{"value":17}', File.binread(source))
    end
  end
end
puts 'PASS unsafe document and lock paths remain rejected without changing their targets'

Dir.mktmpdir('k03-storage-denied-') do |directory|
  storage = T::LocalReadinessStorage.new(directory: directory, guard: -> {})
  validate = ->(document) { assert(document.is_a?(Hash)) }
  storage.access(validate: validate) { storage.write('value' => 1) }
  before = File.binread(storage.path)
  original = File.method(:rename)
  denied = Errno::EACCES.new('Isolated replacement denial')
  attempts = 0
  File.define_singleton_method(:rename) do |source, destination|
    if destination == storage.path
      attempts += 1
      raise denied
    end
    original.call(source, destination)
  end
  begin
    error = assert_raises(T::ReadinessContract::PortUnavailable) do
      storage.access(validate: validate) { storage.write('value' => 2) }
    end
    assert(error.cause.equal?(denied), 'Keep the original filesystem error')
    assert_equal(1, attempts, 'Do not hide refusal by retrying the write')
    assert_equal(before, File.binread(storage.path))
    assert_equal([], Dir.glob(storage.path + '.tmp-*'))
  ensure
    File.define_singleton_method(:rename, original)
  end
  assert_equal({'value' => 1}, storage.access(validate: validate) { |document| document })
end
puts 'PASS real replacement denial is preserved, the old document survives and the lock is released'
