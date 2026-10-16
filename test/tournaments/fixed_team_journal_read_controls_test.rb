# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
rows = []
execution_for(context, record, 'Ala') do |facade|
  request = select_match(facade, record)[:request].to_h
  journal = T::CoordinationJournal.new(directory: File.join(context.directory, 'kontrola-dziennika'),
    scope: request['scope'], account: 'ala', registry: REGISTRY, io: ->(cleanup: false, &block) { block.call })
  journal.with_attempt do
    healthy = {'schema_version' => 1, 'scope' => request['scope'], 'account' => 'ala', 'operations' => []}
    [[:zdrowy, JSON.generate(healthy)], [:parser, '{'], [:schemat, JSON.generate(healthy.merge('operations' => false))]].each do |name, bytes|
      File.binwrite(journal.path, bytes)
      caught = nil; actual = nil
      begin
        actual = journal.records(request)
      rescue T::CoordinationJournal::Corrupt => error
        caught = error
      end
      assert_equal(bytes, File.binread(journal.path))
      name == :zdrowy ? assert_equal([], actual) : assert(caught.instance_of?(T::CoordinationJournal::Corrupt))
      rows << {name: name, bytes: bytes, result: actual, error: caught && {class: caught.class.name, message: caught.message}}
    end
  end
end
oracle_file('journal-read-controls.json', rows)
puts 'GREEN: zdrowy dokument bez zapisu, błędny JSON i legalnie parsowalny błędny schemat jako Corrupt'
