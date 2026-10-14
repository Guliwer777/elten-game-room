require 'json'
require 'digest'
require 'zip'
require 'zstd-ruby'
require 'stringio'
require File.join(ENV.fetch('ELTEN_HOST_SOURCE'), 'src/eapi/ProgramSigning.rb')
package, inventory_path, report_path = ARGV
expected = JSON.parse(File.binread(inventory_path)).fetch('files').to_h { |row| [row.fetch('path').downcase, row] }
actual = {}
add = lambda do |name, bytes|
  name = name.downcase
  raise "Duplicate entry: #{name}" if actual.key?(name)
  actual[name] = {'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes)}
end
Zip::File.open(package) do |zip|
  setup = JSON.parse(zip.read('__manifest.json'))
  entry = setup.fetch('payload').fetch('entry')
  decoded = Programs::ProgramSigning.decode_package(zip.read(entry))
  raise 'Expected developer unsigned package' if decoded[:signed]
  io = StringIO.new(decoded.fetch(:code_file))
  magic = 'Elten3AppPackage'
  raise 'Invalid code header' unless io.read(magic.bytesize) == magic
  u32 = -> { io.read(4).unpack1('V') }
  metadata = JSON.parse(Zstd.decompress(io.read(u32.call)))
  raise 'Wrong application' unless metadata['id'] == 'c24d98cc-9ccd-4d50-b801-459da324ff60'
  until io.eof?
    type = io.read(1).unpack1('C')
    raise "Unexpected record type #{type}" unless [1, 2, 3].include?(type)
    name = type == 3 ? "locale/#{io.read(2)}.mo" : io.read(io.read(2).unpack1('v'))
    bytes = io.read(u32.call)
    add.call(name, type == 2 ? bytes : Zstd.decompress(bytes))
  end
  zip.each do |item|
    next if item.directory? || [entry, '__manifest.json'].include?(item.name)
    add.call(item.name, zip.read(item.name))
  end
end
raise "Wrong file set: missing #{expected.keys - actual.keys}, extra #{actual.keys - expected.keys}" unless actual.keys.sort == expected.keys.sort
expected.each do |name, row|
  raise "Bytes differ: #{name}" unless actual[name]['bytes'] == row['bytes'] && actual[name]['sha256'] == row['sha256']
end
%w[__app.rb lib/tournaments/hub.rb lib/tournaments/shared_hub.rb lib/tournaments/server_workspace.rb lib/tournaments/ui_dialogs.rb games/base/tournaments.rb locale/pl.mo].each { |name| actual.fetch(name) }
%w[local_test_hub local_workspace local_test_tables local_test_dialogs server_trial_hub server_trial_workspace draft_workspace local_tournament_dispatcher local_realtime_game_dialog].each do |name|
  raise "Test-only runtime module retained: #{name}" if actual.key?("lib/tournaments/#{name}.rb")
end

report = {state: 'PASS', unsigned: true, files: actual.size, bytes: File.size(package), sha256: Digest::SHA256.file(package).hexdigest}
File.binwrite(report_path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(report)
