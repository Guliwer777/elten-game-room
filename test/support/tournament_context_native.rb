require_relative 'tournament_native'
require EltenTestHost.file('src/ui/controls/menu.rb')
Object.const_set(:Menu, EltenAPI::Controls.const_get(:Menu)) unless defined?(Menu)
require EltenTestHost.file('src/eapi/mainmenu.rb')

module TournamentNativeContext
  module_function

  def items(form)
    previous = $activecontrols
    # FormBase#update registers the form before its focused control. Exercise
    # the host's complete menu builder in that order, not just ListBox#context.
    $activecontrols = [form, form.fields.fetch(form.index)]
    GlobalMenu.ctitems
  ensure
    $activecontrols = previous
  end
end
