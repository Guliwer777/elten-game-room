# encoding: UTF-8
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
root = Dir.mktmpdir('durable-save-reconcile-', ENV.fetch('TMPDIR'))
worker = File.expand_path('../support/durable_save_reconcile_process.rb', __dir__)
puts "Izolowane dane próby komponentu: #{root}"
results = %w[A B].map do |phase|
  output, status = Open3.capture2e(RbConfig.ruby, worker, phase, root)
  File.binwrite(File.join(root, "#{phase}-raw.bin"), output)
  puts output.force_encoding('UTF-8')
  raise "Proces #{phase} zakończył się kodem #{status.exitstatus}" unless status.success?
  JSON.parse(File.binread(File.join(root, "#{phase}.json")))
end
raise 'Powtórzono PID' if results[0]['pid'] == results[1]['pid']
puts JSON.generate('wynik'=>'PASS komponent persistence/reconcile, NIE całe wznowienie',
  'cold_processes'=>results.map { |r| r['pid'] }, 'observation'=>results[1])
