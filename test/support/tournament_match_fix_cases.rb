# encoding: UTF-8
require_relative 'tournament_match_invitation'
require 'timeout'

# Osobne, trwałe regresje naprawy; pomocnik nie uruchamia scenariuszy przy imporcie.
module TournamentMatchFixCases
  class ProgramError < StandardError; end
  module_function

  def exception(message, klass = ProgramError, cause = ArgumentError.new('Przyczyna fixture'))
    begin
      raise klass.new(message), cause: cause
    rescue StandardError => error
      error
    end
  end

  def caught
    yield
    nil
  rescue StandardError => error
    error
  end

  def run(label)
    row = { 'scenario' => label }
    begin
      yield row
      row['passed'] = true
    rescue StandardError => error
      row['passed'] = false
      row['failure'] = error.full_message
    end
    (@rows ||= []) << row
    puts JSON.generate(row)
  end

  def finish
    if ENV['MATCH_EVIDENCE_DIR']
      File.write(File.join(ENV.fetch('MATCH_EVIDENCE_DIR'), 'observations.json'), JSON.pretty_generate(@rows), encoding: 'UTF-8')
    end
    failures = @rows.reject { |row| row['passed'] }
    assert(failures.empty?, "Nieudane regresje: #{failures.map { |row| row['scenario'] }.join(', ')}")
    puts "PASS regresje: #{@rows.size} scenariuszy"
  end

  def state(scenario, row)
    row.merge!('establish' => scenario.membership.establish_count, 'release' => scenario.membership.release_count,
      'leave' => scenario.calls[:leave], 'complete' => scenario.calls[:complete], 'old_present' => scenario.old_present?)
  end

  def other_room(scenario)
    $game_room_test_user = 'Bob'
    other = scenario.bob.transport.create_room(name: 'Inny publiczny cel fixture',
      game: scenario.binding.to_h['game_id'], owner: 'Bob',
      game_options: JSON.generate(scenario.binding.to_h['options']), private_table: false)
    $game_room_test_user = 'Alice'
    other
  end
end
