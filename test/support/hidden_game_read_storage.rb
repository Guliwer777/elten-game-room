require_relative 'hidden_submission_files'

# The normal ProgramStorage file reader, with a controlled read error rather
# than a substituted Vault result. No installed profiles or live accounts.
class HiddenGameReadStorage < HiddenSubmissionFiles::Storage
  attr_accessor :unreadable
  attr_reader :reads

  def initialize(program)
    super
    @reads = 0
  end

  private

  def read_snapshot_file(path)
    @reads += 1
    raise Errno::EACCES, 'temporary private game file read lock' if unreadable
    super
  end
end
