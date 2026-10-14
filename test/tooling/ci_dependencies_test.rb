require 'yaml'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
workflow = YAML.safe_load(File.read(File.join(root, '.github/workflows/tests.yml')))
steps = workflow.fetch('jobs').fetch('test').fetch('steps')
tests = steps.index { |step| step['name'] == 'Run tests' }
zip = steps.index { |step| step['run'].to_s.include?('gem install rubyzip --version 3.2.2') }
assert(zip && tests && zip < tests, 'Install the host ZIP dependency before loading application tests')
assert(!steps.fetch(zip).key?('if'), 'All CI suites load quiz delivery and require rubyzip, not just native tests')
assert(File.read(File.join(root, 'lib/quiz_contributions/delivery.rb')).include?("require 'zip'"))
puts 'PASS shared ZIP runtime dependency is installed before every CI test suite'
