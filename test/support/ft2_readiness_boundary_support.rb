# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
require 'digest'

module FT2ReadinessBoundarySupport
  F = TournamentReadinessFixture
  J = GameRoomTournaments::ReadinessJournal
  C = GameRoomTournaments::ReadinessContract
  module_function

  def map(directory)
    Dir.glob(File.join(directory, '**', '*')).select { |p| File.file?(p) }.to_h do |path|
      [path, Digest::SHA256.file(path).hexdigest]
    end
  end

  def locks(directory)
    Dir.glob(File.join(directory, '**', '*.lock')).to_h do |path|
      File.open(path, File::RDWR) { |file| [path, !!file.flock(File::LOCK_EX | File::LOCK_NB)] }
    end
  end

  def journal(directory, io)
    J.new(directory: directory, scope: F.scope, match_ref: F.match_ref, account: 'alice', io: io)
  end

  def persist(name, value)
    File.open(File.join(ENV.fetch('ENTRY_EVIDENCE'), name), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(value)) }
  end

  def prepare
    directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')))
    Dir.mkdir(directory)
    port = F::Port.new
    context = F::Context.new
    service = F.service(directory, port, context)
    initial = service.current(scope: F.scope, match_ref: F.match_ref)
    F.assert(initial[:state] == :confirmed && initial[:current]['ready_revision'] == 0, 'Zdrowy początkowy odczyt')
    F.assert(Dir.children(directory).empty?, 'Odczyt bez intencji')
    declared = service.declare(request: F.request)
    F.assert(declared[:state] == :confirmed, 'Zdrowa deklaracja przez prawdziwy Service/Journal')
    readback = F.service(directory, port, context).reconcile(scope: F.scope, match_ref: F.match_ref, operation_id: declared[:operation_id])
    F.assert(readback == declared, 'Dokładny readback wcześniejszej deklaracji')
    [directory, port, context, declared]
  end
end
