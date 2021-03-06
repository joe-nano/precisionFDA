module Permissions
  extend ActiveSupport::Concern

  module ClassMethods
    def can_be_in_space?
      true
    end

    def accessible_by(context)
      if context.guest?
        accessible_by_public
      else
        raise unless context.user_id.present? && context.user.present?

        query = where(user_id: context.user_id, scope: "private").
          or(where(scope: "public")).
          or(where(scope: context.user.space_uids))

        query = query.or(where(user_id: User.challenge_bot.id)) if context.challenge_evaluator?

        query
      end
    end

    def editable_by(context)
      if context.guest?
        none
      else
        return false if try(:space_object).try(:verified?)

        raise unless context.user_id.present?
        records = where(user_id: context.user_id)
        return records unless can_be_in_space?
        records.where(scope: ["public", "private"] + context.user.space_uids)
      end
    end

    def editable_in_space(context, ids)
      if context.guest?
        none
      else
        return false if try(:space_object).try(:verified?)
        raise unless context.user_id.present?
        where(user_id: ids)
      end
    end

    def accessible_by_public
      where(scope: "public")
    end

    def accessible_by_private
      where(scope: "private")
    end

    def accessible_by_space(space)
      where(scope: space.uid)
    end

    def map_context_slice(context, *args)
      self.map { |o| o.context_slice(context, *args) }
    end
  end

  def accessible_by?(context)
    if context.guest?
      public?
    elsif context.logged_in?
      return true if public?
      return true if !in_space? && user_id == context.user_id
      return true if context.user.space_uids.include?(scope)

      context.challenge_evaluator? && user.dxuser == CHALLENGE_BOT_DX_USER
    else
      false
    end
  end

  def editable_by?(context)
    return false if context.guest?

    return false if in_locked_verification_space?

    return user_id == context.user_id unless in_space?

    return false unless context.user.space_uids.include?(scope)
    SpaceMembershipPolicy.can_modify_content?(space_object, self, context.user)
  end

  # Check if the object belongs to current user
  # @param context [Context] a user which is logged in
  # @return [true, false] Returns true if the object belongs to current user,
  #   false otherwise.
  def owned_by?(context)
    user_id == context.user_id
  end

  # Helper method, not to be called from outside the model
  def core_publishable_by?(context, scope_to_publish_to)
    if context.guest?
      false
    else
      return false unless user_id == context.user_id
      core_publishable_by_user?(context.user, scope_to_publish_to)
    end
  end

  def core_publishable_by_user?(user, scope_to_publish_to)
    return false unless user
    user_id == user.id && (private? || in_space?)
  end

  # Check, whether file is piblishable, i.e. to be 'public'.
  #   A file should have scope 'private' or in space.
  # @param user [User] a user object, who is going to publish
  # @return [true, false] Returns true if a file can be published by a user,
  #   false otherwise.
  def publishable?(user)
    return false unless user

    private? || in_space?
  end

  def publishable_by?(context, scope_to_publish_to = "public")
    core_publishable_by?(context, scope_to_publish_to)
  end

  def publishable_by_user?(user, scope_to_publish_to = "public")
    core_publishable_by_user?(user, scope_to_publish_to)
  end

  def copyable_to_cooperative_by?(context)
    return false unless in_space?
    return false unless accessible_by?(context)
    return false unless copyable_to_cooperative?
    return false unless space_object.active?
    return true if user_id == context.user_id

    return false unless context.review_space_admin?

    owner = space_object.space_memberships.find_by(user_id: user_id)
    owner.present? ? owner.host? : true
  end

  def copyable_to_cooperative?
    return false unless in_confidential_space?
    self.class.where(dxid: dxid, scope: space_object.shared_space.uid).empty?
  end

  def public?
    scope == "public"
  end

  def private?
    scope == "private" || scope.nil?
  end

  def in_locked_verification_space?
    in_space? && space_object.verified?
  end

  def in_verificaiton_space?
    in_space? && space_object.verification?
  end

  def in_space?
    !public? && !private?
  end

  def in_confidential_space?
    in_space? && space_object.confidential?
  end

  def space_object
    raise unless in_space?
    Space.from_scope(scope)
  end

  def context_slice(context, *args)
    wrapper = {id: id, uid: uid, klass: klass, scope: scope, item: accessible_by?(context) ? self.slice(*args) : nil}
  end
end
