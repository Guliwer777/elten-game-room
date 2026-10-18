require 'json'
require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckNativeChallengeTipsContractTest
  include DuckClientTest

  EXTRA_TIP = 'An independently registered control tip.'.freeze

  def run
    @driver = DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    cases = %w[simon rhythm hit_duck sound_memory].map do |kind|
      [kind, -> { practice_transitions(kind) }]
    end
    cases << ['native list and edit tips', -> { inherited_tips }]
    results = cases.map do |name, action|
      begin
        action.call
        {case: name, status: 'PASS'}
      rescue StandardError => error
        {case: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
      ensure
        close
        $lastactivecontrols = $activecontrols = []
      end
    end
    puts JSON.pretty_generate(results: results, checks: @checks)
    assert(results.all? { |row| row[:status] == 'PASS' }, 'Native challenge tips did not follow the current phase')
  end

  def practice_transitions(kind)
    setup_client(kind, phase: :preparing)
    @layout = GameRoomLayout::Screen.new(view_spec: view, user_items: @replay.players,
      users_header: 'Players', own_table: true)
    @surface, @form = @layout.surface, @layout.form
    @client.attach_view(@form, @surface)
    field = @surface.fields.first
    field.add_tip(EXTRA_TIP)
    $lastactivecontrols = [@form]
    @form.focus
    initial = @surface.presentation.fetch(:instruction)
    assert(initial.include?('Enter'), 'Fixture never offered initial readiness')
    check_tips(field)

    # Use native Enter, not a readiness setter. The local client updates the
    # same control while the accepted shared start is still outstanding.
    @program.now_ms += 20
    @driver.frame(@form, @driver.tap(0x0D))
    @client.tick
    assert(@client.context_data['duck_ready'])
    assert(@surface.presentation.fetch(:instruction).include?('Waiting'))
    check_tips(field, absent: [initial])
    waiting = @surface.presentation.fetch(:instruction)

    @replay = make_replay(kind)
    @replay.state[:round][:ready] = {0 => true, 1 => true}
    control
    @client.before_wait(@replay, @viewer)
    @layout.update(view_spec: view, history_items: [], user_items: @replay.players,
      users_header: 'Players', own_table: true)
    @surface = @layout.surface
    @client.attach_view(@form, @surface)
    assert(field.equal?(@surface.fields.first), 'A same-mode accepted start replaced the control')
    assert(!@surface.presentation[:practice])
    check_tips(field, absent: [initial, waiting])

    # Native get_tips is what the host's help collector calls. Neither help
    # reads nor repeated view refreshes may append the old/new tip repeatedly.
    current = field.get_tips
    40.times do
      @surface.present(@client.local_view)
      assert_equal(current, field.get_tips)
    end
  end

  def inherited_tips
    %w[rock_paper_scissors copy_number quiz].each do |kind|
      model = challenge_state(kind)
      surface = challenge_surface(model)
      field = surface.fields.first
      field.add_tip(EXTRA_TIP)
      native_class = field.is_a?(EditBox) ? EditBox : ListBox
      native = native_class.instance_method(:tips).bind_call(field)
      tips = field.get_tips
      assert(native.all? { |tip| tips.include?(tip) }, 'Challenge help removed native control instructions')
      assert_equal(1, tips.count(EXTRA_TIP))
      instruction = surface.presentation.fetch(:instruction)
      assert_equal(instruction.empty? ? 0 : 1, tips.count(instruction))
      10.times { surface.present(ENGINE.view(model, seat: 0)); assert_equal(tips, field.get_tips) }
    end
  end

  def check_tips(field, absent: [])
    instruction = @surface.presentation.fetch(:instruction)
    tips = field.get_tips
    assert_equal(1, tips.count(instruction), 'Native help retained an earlier challenge instruction')
    assert_equal(1, tips.count(EXTRA_TIP), 'Dynamic help removed or duplicated another custom tip')
    absent.each { |old| assert(!tips.include?(old), 'Native help still offers an earlier phase') }
  end

  def view
    GameRoomLayout::ViewSpec.new(surface: @client.surface_spec(@replay, @viewer))
  end
end

DuckNativeChallengeTipsContractTest.new.run
