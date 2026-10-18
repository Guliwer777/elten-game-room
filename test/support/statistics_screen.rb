require_relative 'native_tasks'

# Existing rendering/clock fixtures supply synchronous form drivers rather
# than a host event loop. Drain only the statistics callback between their
# explicit actions; the separate async test drives the real native Form.
def settle_statistics(form)
  update = form.instance_variable_get(:@statistics_update)
  return unless update
  Timeout.timeout(5) do
    Thread.pass while update.call
  end
end
