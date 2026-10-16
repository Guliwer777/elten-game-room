# encoding: UTF-8
require_relative 'tournament_public_service'
require_relative 'tournament_entry_context'
require_relative '../../lib/tournaments/local_workspace'

# Wyłącznie testowy magazyn i porty pamięciowe; brak importu *_test.rb.
module TournamentMatchEntryTest
  extend TournamentPublicServiceSupport
  module_function

  def prepare(directory)
    program = TournamentEntryContextTest::Program.new(directory)
    now = 150
    alert = ->(message) { raise message }
    workspace = lambda do |actor|
      GameRoomTournaments::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
        user: -> { 'RealOwner' }, actor: actor, alert: alert, clock: -> { now })
    end
    %w[chess three_five_eight].each do |game|
      author = workspace.call('Organizator')
      result = author.publish(**params(game, draft: draft(game).merge('rematch' => true), timezone: 'local_test:system'))
      raise 'Niepotwierdzona publikacja fixture' unless result['status'] == 'confirmed'
      row = author.load['announcements'].find { |item| item['game'] == game }
      # This fixture exercises four named competitors, not the organizer.
      author.withdraw(row['__id'])
      %w[Alicja Bob Celina Dawid].each do |actor|
        result = workspace.call(actor).join(row['__id'])
        raise 'Niepotwierdzony join fixture' unless result['status'] == 'confirmed'
      end
    end
    program
  end

  def forbid_effects
    TracePoint.new(:call) do |event|
      next if event.defined_class == GameRoomBackground::Work && event.method_id == :start
      if event.path.include?('/lib/') && [:publish, :join, :request_match, :reserve, :create_bind,
          :invite, :establish, :leave, :start, :declare_readiness].include?(event.method_id)
        raise "Niedozwolony skutek podczas odczytu: #{event.defined_class}##{event.method_id}"
      end
    end
  end

  def files(directory)
    Dir.glob('**/*', base: directory).select { |path| File.file?(File.join(directory,path)) }.to_h do |path|
      [path, File.binread(File.join(directory,path))]
    end
  end
end

module EltenAPI
  def loop_update
    $entry_task_tick&.call
    Thread.pass
  end
end
