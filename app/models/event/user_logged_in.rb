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

class Event::UserLoggedIn < Event
  def self.create_for(user)
    create(
      dxuser: user.dxuser,
      org_handle: user.org.handle
    )
  end
end
