module SpaceService
  class Create
    # @param [SpaceForm] space_form
    def self.call(space_form, options = {})
      new(options).call(space_form)
    end

    def initialize(user:, api:, notification_mailer: NotificationsMailer)
      @api = api
      @notification_mailer = notification_mailer
      @user = user
    end

    # Creates a space based on space_form data and returns new space
    # @param [
    #   SpaceForm, #name, #description, #space_type, #cts, #host_lead_dxuser,
    #   #guest_lead_dxuser, #sponsor_org
    # ] space_form
    # @return [Space]
    def call(space_form)
      Space.transaction do
        space = build_space(space_form)
        org_dxs = [space.host_dxorg, space.guest_dxorg].uniq.compact
        create_orgs(org_dxs)
        space.save!
        add_leads(space, space_form)

        if space.review?
          create_reviewer_cooperative_project(space)
          create_reviewer_confidential_space(space, space_form)
        else
          remove_pfda_admin_user(org_dxs)
        end

        send_emails(space)
        space
      end
    end

    private

    attr_reader :user, :api, :notification_mailer

    def build_space(space_form)
      uuid = SecureRandom.hex

      space = Space.new(
        name: space_form.name,
        description: space_form.description,
        host_dxorg: Org.construct_dxorg("space_host_#{uuid}"),
        space_type: space_form.space_type,
        cts: space_form.cts,
        space_template_id: space_form.space_template_id,
        restrict_to_template: space_form.restrict_to_template,
      )
      space.guest_dxorg = guest_dx_org(uuid, space, space_form)
      space.sponsor_org_id = space_form.space_sponsor.org_id if space.review?
      # TODO: set up a migration to add sponsor_lead_dxuser?
      # space.sponsor_lead_dxuser = space_form.sponsor.id if space.review?
      space
    end

    # Provision Host and Guest orgs
    def create_orgs(orgs_dxs)
      orgs_dxs.each { |dxorg| OrgService::Create.call(api, dxorg) }
    end

    # Add host and guest leads as ADMINs
    # @param [Space]
    # @param [SpaceForm]
    def add_leads(space, space_form)
      form_host_lead_dxuser = space_form.host_lead_dxuser
      add_lead(
        space,
        User.find_by!(dxuser: form_host_lead_dxuser),
        SpaceMembership::SIDE_HOST,
      )
      return if guest_blank?(space, space_form)

      form_guest_lead_dxuser = space_form.guest_lead_dxuser
      add_lead(
        space,
        space.review? ? space_form.space_sponsor : User.find_by!(dxuser: form_guest_lead_dxuser),
        SpaceMembership::SIDE_GUEST,
      )
    end

    def add_lead(space, user, side)
      SpaceMembershipService::CreateLead.call(
        papi,
        space,
        user,
        side,
      )
    end

    # Remove pfda admin from orgs
    # Skip if the host user is actual ADMIN_USER
    def remove_pfda_admin_user(orgs_dxs)
      return if user.dxid == ADMIN_USER

      orgs_dxs.each { |dxorg| papi.call(dxorg, "removeMember", user: ADMIN_USER) }
    end

    # Send an activation email to all space leads
    # @param [Space]
    def send_emails(space)
      space.leads.find_each do |lead|
        notification_mailer.space_activation_email(space, lead).deliver_now!
      end
    end

    # Create a project of a cooperative review space.
    # @param [Space]
    def create_reviewer_cooperative_project(space)
      if ADMIN_USER != user.dxid
        papi.call(
          space.host_dxorg, "invite",
          invitee: user.dxid,
          level: "ADMIN",
          suppressEmailNotification: true
        )
      end

      project_dxid = api.call(
        "project", "new",
        name: "precisionfda-space-#{space.id}-HOST",
        billTo: user.billto,
      )["id"]

      api.call(
        project_dxid, "invite",
        invitee: space.host_dxorg,
        level: "CONTRIBUTE",
        suppressEmailNotification: true,
        suppressAllNotifications: true
      )

      api.call(
        project_dxid, "invite",
        invitee: space.guest_dxorg,
        level: "CONTRIBUTE",
        suppressEmailNotification: true,
        suppressAllNotifications: true
      )

      api.call(
        project_dxid, "invite",
        invitee: Setting.review_app_developers_org,
        level: "CONTRIBUTE",
        suppressEmailNotification: true,
        suppressAllNotifications: true,
      )

      space.host_project = project_dxid
      space.save!
    end

    # Create a project of a confidential review space.
    # @param [Space]
    # @param [SpaceForm]
    def create_reviewer_confidential_space(shared_space, space_form)
      space = shared_space.confidential_spaces.create!(
        name: shared_space.name,
        description: shared_space.description,
        space_type: shared_space.space_type,
        cts: shared_space.cts,
        state: shared_space.state,
        host_dxorg: shared_space.host_dxorg,
        restrict_to_template: space_form.restrict_to_template,
      )

      project_dxid = api.call(
        "project", "new",
        name: "precisionfda-space-#{space.id}-REVIEWER-PRIVATE",
        billTo: user.billto,
      )["id"]

      space.host_project = project_dxid
      space.save!

      api.call(
        project_dxid, "invite",
        invitee: space.host_dxorg,
        level: "CONTRIBUTE",
        suppressEmailNotification: true,
        suppressAllNotifications: true,
      )

      api.call(
        project_dxid, "invite",
        invitee: Setting.review_app_developers_org,
        level: "CONTRIBUTE",
        suppressEmailNotification: true,
        suppressAllNotifications: true,
      )

      apply_space_template(space)
    end

    # TODO: to be refactored
    # Apply space_template to the space if space_template exists
    # @param [Space]
    def apply_space_template(space)
      parent_space = space.space
      return if parent_space.blank?

      template = parent_space.space_template
      return if template.blank?

      template.space_template_nodes.each do |n|
        node = n.node
        case node
        when UserFile
          copy_service.copy(node, space.uid)
        when App
          copy_service.copy(node, space.uid)
        else
          raise("Space template #{template.id} has Unexpected node #{n.id} of #{node.class} class")
        end
      end
    end

    def papi
      @papi ||= DNAnexusAPI.for_admin
    end

    def copy_service
      @copy_service ||= CopyService.new(api: api, user: user)
    end

    def guest_dx_org(uuid, space, space_form)
      return if guest_blank?(space, space_form)
      return Org.construct_dxorg("space_host_#{uuid}") if guest_and_host_equal?(space, space_form)

      Org.construct_dxorg("space_guest_#{uuid}")
    end

    def guest_and_host_equal?(space, space_form)
      return false unless space.verification?

      space_form.guest_lead_dxuser == space_form.host_lead_dxuser
    end

    def guest_blank?(space, space_form)
      space.verification? && space_form.guest_lead_dxuser.blank?
    end
  end
end
