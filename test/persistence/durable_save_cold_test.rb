# encoding: UTF-8
require_relative '../support/temporary_directory'
require 'json'
require 'open3'
require 'rbconfig'
root = GameRoomTest::TemporaryDirectory.create('durable-save-cold-')
worker = File.expand_path('../support/durable_save_process.rb', __dir__)
puts "Izolowane dane próby: #{root}"
results = %w[A B].map do |phase|
  output, status = Open3.capture2e(RbConfig.ruby, worker, phase, root)
  File.binwrite(File.join(root, "#{phase}-raw.bin"), output)
  puts output.force_encoding('UTF-8')
  raise "Proces #{phase} zakończył się kodem #{status.exitstatus}" unless status.success?
  JSON.parse(File.binread(File.join(root, "#{phase}.json")))
end
raise 'Powtórzono PID' if results[0]['pid'] == results[1]['pid']
puts JSON.generate('wynik'=>'PASS','cold_processes'=>results.map { |r| r['pid'] },'observation'=>results[1],'fixture_root'=>root)
