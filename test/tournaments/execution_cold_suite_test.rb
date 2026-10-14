# encoding: UTF-8
require_relative '../support/tournament_execution_suite'
TournamentExecutionSuite.run('cold', only: ARGV.first)
