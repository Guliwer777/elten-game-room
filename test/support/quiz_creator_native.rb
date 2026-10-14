require_relative 'game_option_editor_native'
require EltenTestHost.file('src/ui/controls/menu.rb')
Object.const_set(:Menu, EltenAPI::Controls.const_get(:Menu))
def loop_update(*_arguments); end
class Form
  class << self
    attr_accessor :driver
  end
  def wait
    raise 'Unexpected form without test driver' unless Form.driver
    Form.driver.call(self)
  end
end
$assertions = 0
def assert(condition, message)
  $assertions += 1
  raise message unless condition
end
