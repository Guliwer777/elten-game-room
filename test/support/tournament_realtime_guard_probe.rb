require_relative 'tournament_native'
require EltenTestHost.file('src/ui/controls/grid_box.rb')
Object.const_set(:GridBox, EltenAPI::Controls.const_get(:GridBox)) unless defined?(GridBox)
require_relative 'tournament_individual_execution'
require_relative '../../lib/tournaments/local_realtime_individual_execution'
require_relative '../../lib/tournaments/local_realtime_game_dialog'
include TournamentIndividualExecutionSupport

# Run in a fresh native-UI process against the parent's genuinely completed
# local match. The owner of these temporary files stays unchanged; the test
# participant is deliberately not that signed-in account.
directory = ARGV.fetch(0)
path = File.join(directory, 'k02/individual-v1/execution-v1/state.json')
before = File.binread(path)
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(directory, reopen: true, game: 'axel_pong')
begin
  record = fixture.backend.readback(intent_id: 'local-realtime-game')
  actor = record['evidence']['plan']['matches'].first['players'].first['username']
  with_individual_execution(fixture, record, actor, execution_class: T::LocalRealtimeIndividualExecution) do |execution, authority|
    view = execution.local_game(action: :local_realtime_view)
    assert(view[:status]['finished'] && view[:status]['event_count'] == 7,
      'Guard probe needs a genuinely finished seven-point match')
    context = authority.instance_variable_get(:@entry)
    program = context.instance_variable_get(:@program)
    calls = []
    controller = Object.new
    controller.define_singleton_method(:perform) do |**options|
      calls << options
      raise 'Blocked realtime view must not perform an operation'
    end
    created_session = !defined?(Session)
    Object.const_set(:Session, Module.new) if created_session
    original_name = Session.method(:name) if Session.respond_to?(:name)
    begin
      Session.define_singleton_method(:name) { fixture.owner }
      assert(actor.downcase != Session.name.downcase, 'Test participant must differ from the unchanged file owner')
      dialog = T::MatchEntryScreen::RealtimeGame.new(program: program, controller: controller,
        selectors: {}, result: view, context: context, lease: context.capture)
      driver = TournamentNativeDriver.new
      driver.step(nil) do |form|
        assert(dialog.instance_variable_get(:@blocked), 'Account guard did not block the view')
        assert_equal(nil, dialog.instance_variable_get(:@work))
        assert_equal(nil, dialog.instance_variable_get(:@bridge))
        ['Check status', 'Save finished local match result'].each do |label|
          translated = GameRoomContent.utf8(GameRoomLocalization.translate(label))
          button = form.fields.grep(Button).find { |field| field.label == translated }
          assert(button, "Missing native control: #{label}")
          3.times { button.press }
        end
        dialog.send(:begin_work, action: :finalize_local_game, revision: view[:status]['revision'])
        dialog.send(:advance_entry)
        assert_equal(nil, dialog.instance_variable_get(:@pending), 'A blocked action left pending work')
        assert_equal([], calls)
        assert_equal(before, File.binread(path), 'Blocked view altered the saved match')
      end
      driver.step(nil, [27])
      dialog.run
      driver.finish
      assert_equal([], calls)
      assert_equal(before, File.binread(path), 'Closing the blocked view altered the saved match')
    ensure
      if original_name
        Session.define_singleton_method(:name) { original_name.call }
      elsif !created_session
        Session.singleton_class.send(:remove_method, :name)
      end
      Object.send(:remove_const, :Session) if created_session
    end
  end
ensure
  fixture.close
end
puts 'PASS blocked local realtime result: actual finished game, native controls, no worker/read/write, intact files and Escape'
