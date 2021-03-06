# == Schema Information
#
# Table name: events
#
#  id         :integer          not null, primary key
#  type       :string(255)
#  org_handle :string(255)
#  dxuser     :string(255)
#  param1     :string(255)
#  param2     :string(255)
#  param3     :string(255)
#  created_at :datetime         not null
#  param4     :string(255)
#

class Event::JobClosed < Event
  alias_attribute :dxid, :param1
  alias_attribute :runtime, :param2
  alias_attribute :price, :param3
  alias_attribute :state, :param4

  scope :failed, -> { where(state: Job::STATE_FAILED) }

  def self.create_for(job, user)
    return unless job.terminal?

    create(
      dxid: job.dxid,
      runtime: job.runtime,
      price: job.describe["totalPrice"],
      state: job.state,
      dxuser: user.dxuser,
      org_handle: user.org.handle
    )
  end
end
