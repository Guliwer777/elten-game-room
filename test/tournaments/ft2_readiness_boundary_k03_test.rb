# encoding: UTF-8
require 'json'
require 'digest'
# Stare testy mają tylko lokalne fixture; bez macierzy gier i bez procesów -e.
ENV['ENTRY_SCRATCH'] = ENV.fetch('TMPDIR')
names = %w[readiness_read_test.rb readiness_ready_test.rb readiness_receipts_test.rb readiness_storage_test.rb]
rows = []
at_exit do
  File.open(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'k03-regressions.json'), 'wx:UTF-8') do |file|
    file.write(JSON.pretty_generate({entry_scratch: ENV.fetch('ENTRY_SCRATCH'), tests: rows}))
  end
end
names.each do |name|
  path = File.expand_path(name, __dir__)
  row = {path: path, sha256: Digest::SHA256.file(path).hexdigest, completed: false}
  rows << row
  load(path, true)
  row[:completed] = true
end
puts JSON.generate({old_entrypoints_completed: rows.size})
