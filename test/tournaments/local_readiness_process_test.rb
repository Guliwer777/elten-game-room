# encoding: UTF-8
require_relative '../support/assertions'
require_relative '../support/tournament_environment'
require 'json'
require 'digest'
require 'fileutils'
require 'rbconfig'
require 'timeout'
require 'securerandom'
require_relative '../../lib/tournaments/readiness_request'
include GameRoomTest::Assertions
EVIDENCE=ENV.fetch('ENTRY_EVIDENCE')
JOB=File.expand_path('../support/tournament_local_readiness_process.rb',__dir__)
ROOT=Dir.mktmpdir('cold-cas-', ENV.fetch('TMPDIR'))
FileUtils.mkdir_p(ROOT)
@children=[]
def spawn_case(label,mode,directory,job=nil)
  before=Dir.glob('**/*',base:directory).select { |name| File.file?(File.join(directory,name)) }.to_h do |name|
    [name,Digest::SHA256.file(File.join(directory,name)).hexdigest]
  end
  args=[RbConfig.ruby,JOB,mode,directory,job].compact
  File.write(File.join(EVIDENCE,label+'-before.json'),JSON.pretty_generate({env:ENV.to_h,argv:args,cwd:Dir.pwd,data:before}),encoding:'UTF-8')
  pid=Process.spawn(ENV.to_h,*args,out:File.join(EVIDENCE,label+'.stdout.raw'),err:File.join(EVIDENCE,label+'.stderr.raw'))
  @children << [label,pid]
  pid
end
def join_case(label,pid)
  waited,status=Process.wait2(pid)
  @children.delete([label,pid])
  File.write(File.join(EVIDENCE,label+'-exit.json'),JSON.generate({pid:pid,waited:waited,exit:status.exitstatus,joined:true}),encoding:'UTF-8')
  out=File.binread(File.join(EVIDENCE,label+'.stdout.raw')).force_encoding('UTF-8')
  err=File.binread(File.join(EVIDENCE,label+'.stderr.raw')).force_encoding('UTF-8')
  assert(out.valid_encoding? && err.valid_encoding?,'Niepoprawny UTF-8 potomka')
  raise "Proces #{label} exit #{status.exitstatus}: #{out} #{err}" unless status.success?
  puts out
end
begin
  directory=File.join(ROOT,'cold'); FileUtils.mkdir_p(directory)
  a=spawn_case('cold-A','cold-a',directory); join_case('cold-A',a)
  x=spawn_case('no-resend-A','no-resend',directory)
  y=spawn_case('no-resend-B','no-resend',directory)
  join_case('no-resend-A',x); join_case('no-resend-B',y)
  b=spawn_case('cold-B','cold-b',directory); join_case('cold-B',b)
  assert(a!=b,'Zimne A/B muszą mieć różne PID')
  %w[cas dedup].each do |kind|
    directory=File.join(ROOT,kind); FileUtils.mkdir_p(directory)
    seed=spawn_case(kind+'-seed','seed',directory); join_case(kind+'-seed',seed)
    input=JSON.parse(File.read(File.join(directory,'job.json'),encoding:'UTF-8'))
    if kind=='cas'
      input['operation']=GameRoomTournaments::ReadinessContract.operation(input['request'],'alicja',input['operation']['accepted_match'],SecureRandom.uuid)
    end
    File.write(File.join(directory,'second.json'),JSON.generate(input),encoding:'UTF-8')
    p=spawn_case(kind+'-A','race',directory)
    q=spawn_case(kind+'-B','race',directory,'second.json')
    Timeout.timeout(10) { sleep(0.005) until File.file?(File.join(directory,"waiting-#{p}")) && File.file?(File.join(directory,"waiting-#{q}")) }
    File.write(File.join(directory,'release'),'start')
    join_case(kind+'-A',p); join_case(kind+'-B',q)
    receipts=[p,q].map { |pid| JSON.parse(File.read(File.join(directory,"receipt-#{pid}.json"),encoding:'UTF-8')) }
    assert_equal(kind=='cas' ? %w[confirmed conflict] : %w[confirmed confirmed],receipts.map { |row| row['status'] }.sort)
    assert_equal(receipts.first,receipts.last) if kind=='dedup'
    document=JSON.parse(File.read(File.join(directory,'k03','sandbox-k03.json'),encoding:'UTF-8'))
    assert_equal(1,document['receipts'].count { |row| row['status']=='confirmed' })
  end
ensure
  @children.each { |label,pid| join_case(label,pid) }
end
puts 'PASS zimny A→B, dwa PID bez resend, dwa PID CAS, dwa PID exact dedup; wszystkie join'
