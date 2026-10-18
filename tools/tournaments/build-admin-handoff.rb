require 'json'
require 'digest'
require 'zip'
require_relative '../support/release_files'
require_relative '../../lib/tournaments/server_schema'

# Review bundle only. Does not install, register an application or upload data.
package,inventory,verification,output=ARGV
raise 'Usage: PACKAGE INVENTORY VERIFIED_REPORT NEW_ZIP' unless output
raise 'Output already exists' if File.exist?(output) || File.exist?(output + '.verification.json')
root=File.expand_path('../..',__dir__)
report=JSON.parse(File.read(verification))
raise 'Package not verified' unless report['state']=='PASS' && report['sha256']==Digest::SHA256.file(package).hexdigest
entries={}
%w[lib games content Audio locale LICENSES docs tools test].each do |folder|
  Dir.glob(File.join(root,folder,'**','*'),File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path)
    relative=path.delete_prefix(root+'/').tr('\\','/')
    next if relative.split('/').any?{|part|part.start_with?('.') || %w[__pycache__ node_modules tmp].include?(part)}
    next if %w[.pem .key .pyc .dll .exe].include?(File.extname(path).downcase)
    raise "Source escapes checkout: #{relative}" unless File.realpath(path).tr('\\','/').start_with?(root.tr('\\','/')+'/')
    entries['source/power-games/'+relative]=File.binread(path)
  end
end
%w[__app.rb manifest.json README.md LICENSE THIRD_PARTY_NOTICES.md AGENTS.md CONTRIBUTING.md].each do |name|
  path=File.join(root,name)
  entries['source/power-games/'+name]=File.binread(path) if File.file?(path)
end
entries['client/Power-Games-turnieje-admin.eltsetup']=File.binread(package)
entries['client/inventory.json']=File.binread(inventory)
entries['client/verification.json']=File.binread(verification)
entries['schema/tournament-tables.json']=JSON.pretty_generate({'tables'=>GameRoomTournaments::ServerSchema::PROPOSED_TABLES,
  'notifications'=>true,'coordination'=>'authenticated_client_records','deployment'=>'not_performed_by_this_tool'})+"\n"
entries['README-ADMIN.txt']=<<~TEXT
  POWER GAMES — ADMINISTRATOR REVIEW BUNDLE

  client contains the supplied installer, inventory and verification report.
  Its bytes match the SHA-256 in that report. Check the report for the package's
  version, signature and tested scope; this archive adds no certification.

  source/power-games contains maintained sources, documentation, assets,
  development tools and tests. This is review material, not a release stage.
  schema/tournament-tables.json contains declarations, not a deployment receipt.
  FILES.json lists each bundled file's size and SHA-256, except FILES.json itself.

  Current integration, limitations and release checks:
  source/power-games/docs/TOURNAMENT_ADMIN_HANDOFF.md

  The generator does not install the program, change server tables, publish a
  release or upload files. It excludes hidden paths, temporary directories and
  common key/binary extensions; that filter is not a general credential audit.
  Review the source bundle before sharing it.
TEXT
manifest=entries.sort.map{|name,bytes|{'path'=>name,'bytes'=>bytes.bytesize,'sha256'=>Digest::SHA256.hexdigest(bytes)}}
entries['FILES.json']=JSON.pretty_generate(manifest)+"\n"
Zip::OutputStream.open(output) do |zip|
  entries.sort.each do |name, bytes|
    entry = Zip::Entry.new(output, name.encode(Encoding::UTF_8))
    entry.gp_flags |= Zip::Entry::EFS
    zip.put_next_entry(entry)
    zip.write(bytes)
  end
end
Zip::File.open(output) do |zip|
  # Rubyzip reads names as binary strings even when the UTF-8 flag is present.
  raise 'Archive entry set differs' unless zip.entries.map { |entry| entry.name.b }.sort == entries.keys.map(&:b).sort
  zip.entries.each do |entry|
    raise 'Archive UTF-8 flag missing' if (entry.gp_flags & Zip::Entry::EFS).zero?
    name = entry.name.dup.force_encoding(Encoding::UTF_8)
    raise "Archive bytes differ: #{name}" unless zip.read(entry).b == entries.fetch(name).b
  end
end
result={'state'=>'PASS','files'=>entries.size,'bytes'=>File.size(output),'sha256'=>Digest::SHA256.file(output).hexdigest,
  'installer_sha256'=>report['sha256'],'server_changes_performed'=>false}
File.write(output+'.verification.json',JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
