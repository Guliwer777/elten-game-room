require 'open3'
require 'rbconfig'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
# Load the CLI first, as the full localization checks do. Bundler must expose
# the runtime dependency rather than relying on a lucky earlier require.
source = <<~'RUBY'
  require_relative 'tools/translations'
  require_relative 'games/base'
  raise 'Wrong declared base64 dependency' unless Gem.loaded_specs.fetch('base64').version.to_s == '0.3.0'
  puts Base64.strict_encode64('quiz')
RUBY
output, status = Open3.capture2e(RbConfig.ruby, '-e', source, chdir: root)
assert(status.success?, "Translation bundle cannot load game runtime: #{output}")
assert(output.lines.map(&:strip).include?('cXVpeg=='), 'Game dependency was not usable after Bundler setup')
puts 'PASS translation bundle includes the runtime base64 dependency without preload or network'
