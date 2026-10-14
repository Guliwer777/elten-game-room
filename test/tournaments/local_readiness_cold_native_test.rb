# encoding: UTF-8
require_relative '../support/assertions'
require 'fileutils'
require 'rbconfig'
require 'json'
require 'digest'
include GameRoomTest::Assertions
directory=File.expand_path(File.join(ENV.fetch('TMPDIR'),'cold-native'))
FileUtils.mkdir_p(directory)
job=File.expand_path('../support/tournament_readiness_cold_native_job.rb',__dir__)
%w[a bob b history].each do |mode|
  if mode=='history'
    # Kontrolowana utrata źródła publikacji; kotwice i intencje K03 nietknięte.
    paths=Dir.glob('tournament-local-test-*/tables/*.json',base:directory)
    assert_equal(1,paths.size)
    path=File.join(directory,paths.first)
    File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'publication-before-removal.bin'),File.binread(path))
    File.delete(path)
  end
  prefix=File.join(ENV.fetch('ENTRY_EVIDENCE'),'cold-native-'+mode)
  data=Dir.glob('**/*',base:directory).select { |name|File.file?(File.join(directory,name)) }.to_h do |name|
    [name,Digest::SHA256.file(File.join(directory,name)).hexdigest]
  end
  argv=[RbConfig.ruby,job,mode,directory]
  File.write(prefix+'-before.json',JSON.pretty_generate({env:ENV.to_h,argv:argv,cwd:Dir.pwd,data:data}),encoding:'UTF-8')
  pid=Process.spawn(ENV.to_h,*argv,out:prefix+'.stdout.raw',err:prefix+'.stderr.raw')
  waited,status=Process.wait2(pid)
  File.write(prefix+'-exit.json',JSON.generate({pid:pid,waited:waited,exit:status.exitstatus,joined:true}),encoding:'UTF-8')
  stdout,stderr=['.stdout.raw','.stderr.raw'].map { |suffix|File.binread(prefix+suffix).force_encoding('UTF-8') }
  assert(stdout.valid_encoding? && stderr.valid_encoding?,'Niepoprawny UTF-8')
  raise "Cold native #{mode}: #{stdout}\n#{stderr}" unless status.success?
  puts stdout
end
puts 'PASS rzeczywiste zimne native A/B, odrębny Bob, historyczny odczyt bez źródła; wszystkie procesy joined'
