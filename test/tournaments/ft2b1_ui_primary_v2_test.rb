# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja primary U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = []
begin
  [:main, :details, :deadline].product([:exception, :throw, :lease, :lease_throw], [false, true]).each do |kind, cleanup, with_cause|
    owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
    workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
    screen = T::LocalFixedTeamExecutionScreen.new(program: fixture[:program], workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    active = observed = nil
    reached = 0
    primary = NoMethodError.new('Pierwotny błąd resume FT2')
    primary.set_backtrace(['pierwotny_u.rb:17'])
    cause = with_cause ? ArgumentError.new('Przyczyna U') : nil
    secondary = Exception.new('Wtórny błąd cleanup spoza StandardError')
    secondary.set_backtrace(['wtorny_u.rb:29'])
    invoke = lambda do |form|
      active = form
      form.index = 0
      field = form.fields.first
      field.index, field.check = 3, 7 if field.is_a?(EditBox)
      field.on(:before_focus) do
        reached += 1
        window = form.instance_variable_get(:@hub_interaction).receiver
        assert(window.instance_variable_get(:@busy))
        form.cancel_button.press
        case cleanup
        when :exception then raise secondary, cause: nil
        when :throw then throw :u_secondary_throw, :swallowed
        when :lease then screen.controller.close
        when :lease_throw then screen.controller.close; throw :u_secondary_throw, :swallowed
        end
      end
      catch(:u_secondary_throw) do
        begin
          begin
            raise IOError, 'Obsłużony ambient'
          rescue IOError
            form.game_room_hotkey_action(1).call
          end
        rescue Exception => error
          observed = error
        end
      end
      assert(observed.equal?(primary), "#{kind}/#{cleanup}: zgubiono primary")
      assert(observed.cause.equal?(cause), 'Zmieniono bezpośredni cause')
      assert_equal(['pierwotny_u.rb:17'], observed.backtrace)
      assert_equal(1, reached)
      method = form.instance_variable_get(:@hub_interaction)
      results << {kind: kind, cleanup: cleanup, cause: with_cause, owner: method.owner.name,
        source: method.source_location, super_source: method.super_method&.source_location, reached: reached, backtrace: observed.backtrace}
    end
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Check status').press
      2.times do
        work = screen.instance_variable_get(:@readiness_work)
        wait_background_work(work) if work&.busy?
        form.update
      end
      case kind
      when :main then invoke.call(form)
      when :details then form.accept_button.press
      when :deadline then F.button(form, 'Choose technical deadline').press
      end
    end
    modal = kind == :details ? 'Match details' : 'Technical local trial deadline'
    driver.step(modal) { |form| invoke.call(form) } unless kind == :main
    driver.step('Keyboard shortcuts', [27])
    driver.on_resume = lambda do |form|
      next unless form.fields.first.header == 'Keyboard shortcuts'
      raise primary, cause: cause
    end
    unless [:lease, :lease_throw].include?(cleanup)
      driver.step(modal, [27]) unless kind == :main
      driver.step('Accepted fixed-team plans', [27])
    end
    screen.run; driver.finish
    assert_equal([0, 0], [fixture[:program].managed_resources.size, fixture[:program].class.app_runtime.managed_resources.size])
    assert(driver.forms.all? { |form| form.instance_variable_get(:@entry_depth) == 0 })
    assert(!active.instance_variable_get(:@hub_interaction).receiver.instance_variable_get(:@busy))
  end
  U.evidence('primary-matrix', results)
  puts "PASS primary/cause/backtrace: #{results.size} prób main/details/deadline → F1, wtórny Exception/throw/lease i ambient rescue"
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
