require_relative "../support/hidden_submission_files"
require_relative "../support/assertions"

include GameRoomTest::Assertions

identity = { session_id: 317, round_id: "quiz:2", user: "Alice" }.freeze
main = HiddenSubmissions::ProgramStorage::DEFAULT_PATH
recovery = main + ".recovery.json"
key = Digest::SHA256.hexdigest([317, "quiz:2", "alice"].join("\0"))
variants = []
checks = 0
failures = []

Dir.mktmpdir("game-room-hidden-shape-") do |directory|
  program = HiddenSubmissionFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(program.storage)
  first = vault.prepare(**identity, payload: { "answer" => "żółw" })
  program.blocked = [main]
  second = vault.prepare(**identity, payload: { "answer" => "łęk" })
  fresh = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(directory).storage)
  assert_equal(second, fresh.reveal(**identity), "Cold read lost the recovery envelope")
  assert_equal(first, fresh.reveal(**identity, commitment: first.commitment), "Cold read lost the older envelope")
  assert(fresh.verify(first) && fresh.verify(second), "A valid stored commitment changed")
  assert_equal(second, fresh.prepare(**identity, payload: { "answer" => "łęk" }), "Retry changed an accepted envelope")
  root = JSON.parse(File.binread(File.join(directory, recovery)))
  original = root.fetch("entries").fetch(key)
  malformed = [nil, false, true, [], "broken", 7, 2.5]

  malformed.each do |value|
    variants << ["root_#{value.class}", value]
    variants << ["entries_#{value.class}", root.merge("entries" => value)]
    variants << ["entry_#{value.class}", root.merge("entries" => { key => value })]
    variants << ["versions_#{value.class}", root.merge("entries" => { key => original.merge("versions" => value) })]
    versions = original.fetch("versions").merge(first.commitment => value)
    variants << ["version_#{value.class}", root.merge("entries" => { key => original.merge("versions" => versions) })]
  end
  [nil, false, [], {}, "2", -1, 2.5].each do |value|
    variants << ["revision_#{value.class}", root.merge("storage_revision" => value)]
  end
  %w[session_id round_id user payload nonce commitment].each do |field|
    entry = original.reject { |name, _| name == field }
    variants << ["missing_#{field}", root.merge("entries" => { key => entry })]
  end
  %w[session_id round_id user nonce commitment].each do |field|
    variants << ["object_#{field}", root.merge("entries" => { key => original.merge(field => {}) })]
  end

  variants.each_with_index do |(name, value), index|
    path = File.join(directory, "case-#{index}")
    FileUtils.mkdir_p(path)
    # Keep a genuine older copy beside each malformed primary snapshot. A
    # refusal must not silently turn the bad current copy into empty storage.
    File.binwrite(File.join(path, main), JSON.generate(value))
    File.binwrite(File.join(path, recovery), JSON.generate(root.merge("storage_revision" => 0)))
    before = [main, recovery].to_h { |file| [file, File.binread(File.join(path, file))] }
    faulty_program = HiddenSubmissionFiles.new(path)
    faulty = HiddenSubmissions::Vault.new(faulty_program.storage)
    actions = {
      current: -> { faulty.reveal(**identity) },
      older: -> { faulty.reveal(**identity, commitment: first.commitment) },
      prepare: -> { faulty.prepare(**identity, payload: { "answer" => "new" }) },
      enumerate: -> { faulty.envelopes(session_id: 317, user: "Alice", round_prefix: "quiz:") },
      discard: -> { faulty.discard(**identity) }
    }
    actions.each do |operation, action|
      checks += 1
      begin
        returned = action.call
        failures << "#{name}/#{operation}: no StorageError" unless operation == :discard && returned == false
      rescue HiddenSubmissions::StorageError
        failures << "#{name}/discard: cleanup propagated StorageError" if operation == :discard
      rescue StandardError => error
        failures << "#{name}/#{operation}: #{error.class}"
      end
      [main, recovery].each do |file|
        assert_equal(before.fetch(file), File.binread(File.join(path, file)), "#{name}/#{operation} changed stored bytes")
      end
      assert(faulty_program.writes.empty?, "#{name}/#{operation} attempted to replace an envelope")
    end
  end

  # A pre-revision file produced by the old vault remains readable, including
  # its explicit null payload. The next edit retains that exact old version.
  legacy_directory = File.join(directory, "legacy")
  FileUtils.mkdir_p(legacy_directory)
  legacy_program = HiddenSubmissionFiles.new(legacy_directory)
  memory = HiddenSubmissions::MemoryStorage.new
  legacy = HiddenSubmissions::Vault.new(memory).prepare(**identity, payload: nil)
  File.binwrite(File.join(legacy_directory, main), JSON.generate(memory.read))
  cold = HiddenSubmissions::Vault.new(legacy_program.storage)
  assert_equal(legacy, cold.reveal(**identity), "Legacy envelope without storage revision was rejected")
  edited = cold.prepare(**identity, payload: [1, "two", nil])
  reopened = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(legacy_directory).storage)
  assert_equal(legacy, reopened.reveal(**identity, commitment: legacy.commitment))
  assert_equal(edited, reopened.reveal(**identity))
  assert(reopened.verify(legacy) && reopened.verify(edited))
end

assert(failures.empty?, "Malformed hidden storage was not refused safely:\n#{failures.join("\n")}")
puts "Hidden submission structural boundaries: #{variants.length} shapes / #{checks} operations, cold and legacy roundtrips: OK"
