require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
require 'zip'
require_relative '../../lib/tournaments/server_schema'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
tool = 'tools/tournaments/build-admin-handoff.rb'
Dir.mktmpdir('pg-admin-handoff-') do |temporary|
  fixture = File.join(temporary, 'source')
  copied = {}
  copy_dependency = lambda do |relative|
    return if copied[relative]
    copied[relative] = true
    original = File.join(root, relative)
    destination = File.join(fixture, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(original, destination)
    File.read(original, encoding: 'UTF-8').scan(/\brequire_relative\s*['"]([^'"]+)['"]/).flatten.each do |dependency|
      path = File.expand_path(dependency + (File.extname(dependency).empty? ? '.rb' : ''), File.dirname(original))
      raise 'Fixture dependency escapes repository' unless path.start_with?(root + '/')
      copy_dependency.call(path.delete_prefix(root + '/'))
    end
  end
  copy_dependency.call(tool)
  if ENV['ADMIN_HANDOFF_BASELINE']
    FileUtils.cp(ENV.fetch('ADMIN_HANDOFF_BASELINE'), File.join(fixture, tool))
  end
  %w[docs/TOURNAMENT_ADMIN_HANDOFF.md docs/TOURNAMENT_SERVER_INTEGRATION.md README.md].each do |relative|
    FileUtils.mkdir_p(File.dirname(File.join(fixture, relative)))
    FileUtils.cp(File.join(root, relative), File.join(fixture, relative))
  end
  %w[lib/.hidden.rb lib/key.pem lib/key.key lib/tmp/private.rb].each do |relative|
    FileUtils.mkdir_p(File.dirname(File.join(fixture, relative)))
    File.write(File.join(fixture, relative), 'excluded fixture')
  end
  assets = {'Audio/krótki dźwięk.opus' => "\x00\xFF\xFEaudio".b, 'content/empty.txt' => ''.b}
  assets.each do |relative, bytes|
    FileUtils.mkdir_p(File.dirname(File.join(fixture, relative)))
    File.binwrite(File.join(fixture, relative), bytes)
  end
  package = File.join(temporary, 'fixture.eltsetup')
  inventory = File.join(temporary, 'inventory.json')
  verification = File.join(temporary, 'verification.json')
  archive = File.join(temporary, 'review.zip')
  File.binwrite(package, "fixture package\x00\xFF".b)
  package_hash = Digest::SHA256.file(package).hexdigest
  File.write(inventory, JSON.generate(files: []))
  File.write(verification, JSON.generate(state: 'PASS', sha256: package_hash, fixture: true))
  run = ->(target) { Open3.capture2e(RbConfig.ruby, File.join(fixture, tool), package, inventory, verification, target) }
  output, status = run.call(archive)
  assert(status.success?, "Handoff failed: #{output}")
  result = JSON.parse(output)
  assert(result['state'] == 'PASS' && result['sha256'] == Digest::SHA256.file(archive).hexdigest, 'Archive receipt mismatch')
  assert(result['server_changes_performed'] == false && !result.key?('contains_credentials'), 'Receipt overclaims deployment or credentials')
  Zip::File.open(archive) do |zip|
    assets.each do |relative, bytes|
      name = 'source/power-games/' + relative
      entry = zip.find_entry(name.b)
      assert(entry && entry.name.b == name.b && (entry.gp_flags & Zip::Entry::EFS) != 0, 'UTF-8 file name flag missing')
      assert(zip.read(entry).b == bytes, 'Unicode-named asset bytes changed')
    end
    assert(zip.find_entry('README-ADMIN.txt'), 'Missing current administrator instructions')
    assert(!zip.find_entry('README-ADMIN-PL.txt'), 'Stale hardcoded instructions retained')
    readme = zip.read('README-ADMIN.txt')
    assert(readme.include?('source/power-games/docs/TOURNAMENT_ADMIN_HANDOFF.md'), 'Missing current contract link')
    assert(!readme.include?('unsigned') && !readme.include?('server_implementation_required'), 'Invented signature or server requirement')
    schema = JSON.parse(zip.read('schema/tournament-tables.json'))
    assert(schema['tables'] == GameRoomTournaments::ServerSchema::PROPOSED_TABLES, 'Schema changed while documenting it')
    assert(schema['coordination'] == 'authenticated_client_records' && schema['deployment'] == 'not_performed_by_this_tool', 'False deployment metadata')
    assert(zip.read('client/Power-Games-turnieje-admin.eltsetup').b == File.binread(package), 'Package bytes changed')
    manifest = JSON.parse(zip.read('FILES.json'))
    assert(manifest.map { |row| row.fetch('path').b }.sort == (zip.entries.map { |entry| entry.name.b } - ['FILES.json']).sort, 'Manifest omits or invents files')
    manifest.each do |row|
      bytes = zip.read(row.fetch('path').b)
      assert(bytes.bytesize == row.fetch('bytes') && Digest::SHA256.hexdigest(bytes) == row.fetch('sha256'), 'Bundled bytes mismatch')
    end
    %w[lib/.hidden.rb lib/key.pem lib/key.key lib/tmp/private.rb].each do |relative|
      assert(!zip.find_entry('source/power-games/' + relative), "Excluded file shipped: #{relative}")
    end
    %w[TOURNAMENT_ADMIN_HANDOFF.md TOURNAMENT_SERVER_INTEGRATION.md].each do |name|
      assert(zip.read('source/power-games/docs/' + name).b == File.binread(File.join(root, 'docs', name)), 'Contract bytes changed')
    end
  end
  Zip::InputStream.open(archive) do |zip|
    names = []
    while (entry = zip.get_next_entry)
      assert((entry.gp_flags & Zip::Entry::EFS) != 0, 'Local ZIP header omits UTF-8 flag')
      names << entry.name.b
    end
    assets.each_key { |relative| assert(names.include?(('source/power-games/' + relative).b), 'Local ZIP header changes file name') }
  end
  original_receipt = File.binread(archive + '.verification.json')
  output, status = run.call(archive)
  assert(!status.success? && output.include?('Output already exists'), 'Existing bundle overwritten')
  assert(Digest::SHA256.file(archive).hexdigest == result['sha256'] && File.binread(archive + '.verification.json') == original_receipt, 'Existing bundle or receipt changed')
  orphan = File.join(temporary, 'orphan.zip')
  File.write(orphan + '.verification.json', 'existing receipt')
  output, status = run.call(orphan)
  assert(!status.success? && output.include?('Output already exists') && !File.exist?(orphan), 'Orphan receipt was not protected')
  assert(File.read(orphan + '.verification.json') == 'existing receipt', 'Orphan receipt changed')
  File.write(verification, JSON.generate(state: 'PASS', sha256: 'wrong'))
  invalid = File.join(temporary, 'invalid.zip')
  output, status = run.call(invalid)
  assert(!status.success? && output.include?('Package not verified') && !File.exist?(invalid), 'Unverified package accepted')
end
puts 'PASS administrator review archive: current contracts, exact schema/bytes/inventory, exclusions and non-overwrite boundaries; no real installer or server changes'
