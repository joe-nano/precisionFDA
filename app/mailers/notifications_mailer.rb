class NotificationsMailer < ApplicationMailer
  add_template_helper(SpacesHelper)
  helper :application

  if ENV["DNANEXUS_BACKEND"] == "production"
    default  from: 'PrecisionFDA <PrecisionFDA@fda.hhs.gov>',
             reply_to: "PrecisionFDA@fda.hhs.gov"
  end

  # Subject can be set in your I18n file at config/locales/en.yml
  # with the following lookup:
  #
  #   en.notifications.invitation.subject
  #
  def invitation_email(invitation)
    @invitation = invitation
    recipients = ["precisionfda-support@dnanexus.com"]
    if ENV["DNANEXUS_BACKEND"] == "production"
      recipients << "precisionfda@fda.hhs.gov"
    end

    mail to: recipients,
         reply_to: "precisionfda-support@dnanexus.com",
         subject: "New access request from #{invitation.first_name} #{invitation.last_name}"
  end

  def guest_access_email(invitation)
    @invitation = invitation
    mail to: @invitation.email,
         bcc: "precisionfda-support@dnanexus.com",
         subject: "Your precisionFDA access request"
  end

  def license_request_email(license, user, message)
    @license = license
    @user = user
    @message = message
    mail to: @license.user.email,
         reply_to: @user.email,
         subject: "#{@user.full_name} requested approval to \"#{@license.title}\""
  end

  def license_approved_email(license, user)
    @license = license
    @user = user
    mail to: @user.email,
         reply_to: @license.user.email,
         subject: "You were approved for \"#{@license.title}\""
  end

  def license_revoked_email(license, user)
    @license = license
    @user = user
    mail to: @user.email,
         reply_to: @license.user.email,
         subject: "Your license was revoked for \"#{@license.title}\""
  end

  def space_activation_email(space, membership)
    @space = space
    @membership = membership
    @user = membership.user
    mail to: @user.email,
         subject: "Action required to activate new space \"#{@space.title}\""
  end

  def space_activated_email(space, membership)
    @space = space
    @membership = membership
    @user = membership.user
    mail to: @user.email,
         subject: "Your space was activated: \"#{@space.title}\""
  end

  def space_invitation_email(space, membership, admin)
    @space = space
    @membership = membership
    @user = membership.user
    @admin = admin
    mail to: @user.email,
         reply_to: admin.user.email,
         subject: "#{admin.user.full_name} added you to the space \"#{space.title}\""
  end

  def external_user_invited_to_space_email(space, email, admin, role)
    @space = space
    @admin = admin
    @role = role
    @email = email

    subject = %(You have been invited to join "#{space.title}" space)

    mail to: email,
         reply_to: admin.user.email,
         subject: subject
  end

  def user_remove_approved_email(org, member, approver)
    @org = org
    @member = member
    @approver = approver

    mail to: @org.admin.email,
         reply_to: @approver.email,
         subject: "#{@approver.full_name} approved your request to remove #{@member.full_name} "\
                  "from your org (\"#{@org.name}\")"
  end

  def user_leave_approved_email(org, member, approver)
    @org = org
    @member = member
    @approver = approver

    mail to: @org.admin.email,
         reply_to: @approver.email,
         subject: "#{@approver.full_name} approved #{@member.full_name}'s request to leave "\
                  "your organization (\"#{@org.name}\")"
  end


  def org_dissolve_approved_email(org, approver)
    @org = org
    @approver = approver

    mail to: @org.admin.email,
         reply_to: @approver.email,
         subject: "#{@approver.full_name} approved your request to dissolve \"#{@org.name}\" org"
  end

  def new_expert_email(expert)
    @expert = expert
    mail to: @expert.user.email,
         subject: "A new Expert Q&A Session was created for \"#{@expert.user.full_name.titleize}\""
  end

  def new_expert_question_email(expert, question)
    @expert = expert
    @question = question
    name = @question.user.nil? ? "Anonymous" : @question.user.full_name.titleize
    mail to: @expert.user.email,
         subject: "A new question was submitted by \"#{name}\""
  end

  def new_task_email(task)
    @task = task
    mail to: @task.assignee.email,
         subject: "Task \"#{@task.name}\" was assigned to you"
  end

  def task_updated_email(task, receiver, action)
    @task = task
    @action = action
    @receiver = receiver
    @task_creator = @task.user.id == @receiver.id ? 'you' : @task.user.full_name
    @task_assignee = @task.assignee.id == @receiver.id ? 'you' : @task.assignee.full_name
    mail to: @receiver.email,
         subject: "Task \"#{@task.name}\" was #{@action}"
  end

  def user_failed_to_acknowledge_task_email(task)
    @task = task
    mail to: @task.user.email,
         subject: "User failed to ackowledge task \"#{@task.name}\""
  end

  def user_failed_to_complete_task_email(task)
    @task = task
    mail to: @task.user.email,
         subject: "User failed to complete task \"#{@task.name}\" in time"
  end

  def challenge_results(file, user_id, test_email=nil)
    @user = User.find(user_id)

    attachments[File.basename(file)] = {
      content: Base64.encode64(File.read(file))
    }

    if test_email.present?
      mail(to: test_email, from: 'notification@dnanexus.com', subject: "Results of NCI-CPTAC challenge")
    else
      mail(to: @user.email, subject: "Results of NCI-CPTAC challenge")
    end
  end
end
