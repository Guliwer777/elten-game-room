require_relative '../support/ui'
require_relative '../support/assertions'
require_relative '../../lib/game_surfaces'

include GameRoomTest::Assertions

spec = GameSurfaces::ReviewSpec.new(id: 'round-1', header: 'Review',
  items: [GameSurfaces::ReviewItem.new(id: 'country', category: 'Country', answer: 'Austria')],
  decisions: [GameSurfaces::ReviewDecision.new(id: 'unique', label: 'Unique'),
    GameSurfaces::ReviewDecision.new(id: 'partial', label: 'Partial')])
surface = GameSurfaces.build(spec)
actions = []
surface.on_action { |action| actions << action }
surface.fields[1].index = 1
surface.action_guard = -> { false }
surface.fields[1].trigger(:select)
assert(actions.empty?, 'A denied review action reached the handler')
assert_equal({}, surface.state['confirmed'], 'A denied Enter falsely confirmed the assessment')
surface.action_guard = nil
surface.fields[1].trigger(:select)
assert_equal(1, actions.length, 'A previously denied choice could not be retried')
assert_equal({}, surface.state['confirmed'], 'A handler invocation falsely confirmed the assessment')

# A screen may reject the action, return a stale-view error, or leave its write
# uncertain. None is acceptance, so choosing the same grade must remain possible.
3.times { surface.fields[1].trigger(:select) }
assert_equal(4, actions.length)
assert_equal({}, surface.state['confirmed'])
surface.action_accepted(actions.last)
assert_equal({'country' => 'unique'}, surface.state['confirmed'])
surface.fields[1].trigger(:select)
assert_equal(4, actions.length, 'An already accepted choice was submitted twice')

# A delayed acknowledgement must not confirm a newer, unsent choice.
surface.fields[1].index = 2
surface.action_accepted(actions.last)
assert_equal({'country' => 'unique'}, surface.state['confirmed'])
surface.fields[1].trigger(:select)
assert_equal(5, actions.length)
surface.action_accepted(actions.last)
assert_equal({'country' => 'partial'}, surface.state['confirmed'])

surface.action_accepted(GameSurfaces::Action.from_h(actions.last.to_h.merge('review_id' => 'round-2', 'decision' => 'unique')))
surface.action_accepted(GameSurfaces::Action.from_h(actions.last.to_h.merge('item_id' => 'unknown', 'decision' => 'unique')))
surface.action_accepted(GameSurfaces::Action.from_h(actions.last.to_h.merge('decision' => 'invalid')))
assert_equal({'country' => 'partial'}, surface.state['confirmed'], 'A stale or invalid acknowledgement changed the confirmed assessment')

# The authoritative specification wins over an old window snapshot after a
# queued assessment or a remote change. Local navigation is still remembered.
restored = GameSurfaces.build(spec, state: surface.state)
assert_equal({}, restored.state['confirmed'], 'An old snapshot overrode the authoritative assessment')
assert_equal({'country' => 'partial'}, restored.state['decisions'])
updated_spec = GameSurfaces::ReviewSpec.new(**spec.to_h.merge(items: [
  GameSurfaces::ReviewItem.new(id: 'country', category: 'Country', answer: 'Austria', decision: 'unique')]))
restored = GameSurfaces.build(updated_spec, state: surface.state)
assert_equal({'country' => 'unique'}, restored.state['confirmed'])

# The source route must select only the original child of a composite surface.
composite = GameSurfaces.build(GameSurfaces::CompositeSpec.new(parts: [
  GameSurfaces::SurfacePart.new(id: 'review', surface: spec),
  GameSurfaces::SurfacePart.new(id: 'other', surface: spec)]))
emitted = nil
composite.on_action { |action| emitted = action }
composite.fields[1].index = 1
composite.fields[1].trigger(:select)
assert_equal('review', emitted.source)
composite.action_accepted(emitted)
assert_equal({'country' => 'unique'}, composite.state['parts']['review']['confirmed'])
assert_equal({}, composite.state['parts']['other']['confirmed'])

puts 'PASS review acceptance: denied/rejected/uncertain attempts stay retryable, explicit acceptance, duplicates, immutable choice, authoritative restore and composite routing'
