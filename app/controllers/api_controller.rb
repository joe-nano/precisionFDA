class ApiController < ApplicationController
  include ErrorProcessable
  include WorkflowConcern

  skip_before_action :verify_authenticity_token
  skip_before_action :require_login
  before_action :require_api_login, except: [:list_apps, :list_assets, :list_comparisons, :list_files, :list_jobs, :list_workflows, :list_notes, :list_related, :describe, :search_assets]
  before_action :require_api_login_or_guest, only: [:list_apps, :list_assets, :list_comparisons, :list_files, :list_jobs, :list_workflows, :list_related, :describe, :search_assets]
  before_action :validate_create_asset, only: :create_asset
  before_action :validate_get_upload_url, only: :get_upload_url

  rescue_from ApiError, with: :render_error_method

  # Inputs
  #
  # scope (string, optional): "public" or "space-123" (default is "public")
  # uids (array of strings): one or more uids to publish to the scope
  #
  # Outputs
  #
  # published (number): the count of published objects
  def publish
    space = nil

    scope = params[:scope]
    if scope.nil?
      scope = "public"
    elsif scope.is_a?(String)
      if scope != "public"
        # Check that scope is a valid scope:
        # - must be of the form space-xxxx
        # - must exist in the Space table
        # - must be accessible by context
        fail "Invalid scope (only 'public' or 'space-xxxx' are accepted)" unless scope =~ /^space-(\d+)$/
        space = Space.find_by(id: $1.to_i)
        fail "Invalid space" unless space.present? && space.active? && space.accessible_by?(@context)
      end
    else
      fail "The optional 'scope' input must be a string (either 'public' or 'space-xxxx')"
    end

    uids = params[:uids]
    fail "The input 'uids' must be an array of object ids (strings)" unless uids.is_a?(Array) && uids.all? { |uid| uid.is_a?(String) }

    items = uids.uniq.map { |uid| item_from_uid(uid) }.reject { |item| item.public? || item.scope == scope }
    fail "Unpublishable items detected" unless items.all? { |item| item.publishable_by?(@context, scope) }

    # Files to publish:
    # - All real_files selected by the user
    # - All assets selected by the user
    files = items.select { |item| item.klass == "file" || item.klass == "asset" }

    # Comparisons
    comparisons = items.select { |item| item.klass == "comparison" }

    # Apps
    apps = items.select { |item| item.klass == "app" }

    # Jobs
    jobs = items.select { |item| item.klass == "job" }

    # Notes
    notes = items.select { |item| item.klass == "note" }

    # Discussions
    discussions = items.select { |item| item.klass == "discussion" }

    # Answers
    answers = items.select { |item| item.klass == "answer" }

    workflows = items.select { |item| item.klass == "workflow" }

    published_count = 0

    # Files
    unless files.empty?
      published_count += UserFile.publish(files, @context, scope)
    end

    # Comparisons
    unless comparisons.empty?
      published_count += Comparison.publish(comparisons, @context, scope)
    end

    # Jobs
    unless jobs.empty?
      published_count += Job.publish(jobs, @context, scope)
    end

    # Notes
    unless notes.empty?
      published_count += Note.publish(notes, @context, scope)
    end

    # Discussions
    unless discussions.empty?
      published_count += Discussion.publish(discussions, @context, scope)
    end

    # Answers
    unless answers.empty?
      published_count += Answer.publish(answers, @context, scope)
    end

    if workflows.any?
      PublishService::WorkflowPublisher.call(workflows, @context, scope)
      published_count += workflows.count

      workflows.flat_map(&:apps).each do |app|
        next if apps.include?(app) || app.public? || app.scope == scope
        apps << app
      end
    end

    # Apps
    unless apps.empty?
      published_count += AppSeries.publish(apps, @context, scope)
    end

    render json: { published: published_count }
  end

  # Inputs:
  #
  # id (Integer; required): app series id
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_app_revisions
    app_series_id = params["id"]
    fail "id needs to be an Integer" unless app_series_id.is_a?(Numeric) && (app_series_id.to_i == app_series_id)
    app_series = AppSeries.accessible_by(@context).find_by(id: params["id"])
    fail "AppSeries not found" if app_series.nil?
    render json: app_series.accessible_revisions(@context).select(:title, :id, :uid, :revision, :version)
  end

  # Inputs
  #
  # workflow_id (string, required): the dxid of the workflow to run
  # inputs (hash, required): the inputs
  # name (string, required): the name of the analysis
  #
  # Outputs
  #
  # id (string, only on success): the id of the created analysis, if success
  # failure (string, only on failure): a message that can be shown to the user due to failure
  def run_workflow
    analysis_dxid = run_workflow_once(params)
    render json: { id: analysis_dxid }
  end

  def to_bool(input)
    return true   if input == 'true'
    return false  if input == 'false'
    raise ArgumentError.new("invalid value for Boolean: \"#{self}\"")
  end

  # Inputs
  # --
  # uid (String, required)
  # opts:
  #       scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  #       classes (Array, optional): array of valid classNames e.g. ["file", "comparison"] or leave blank for all
  #       editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  #       describe (object, optional)
  #         fields (array, optional):
  #             Array containing field name [field_1, field_2, ...]
  #             to indicate which object fields to include
  #         include (object, optional)
  #             license (boolean, optional)
  #             user (boolean, optional)
  #             org (boolean, optional)
  #             all_tags_list (boolean, optional)
  #
  def list_related
    uid = params[:uid]
    item = item_from_uid(uid)

    if item.accessible_by?(@context)
      params[:opts] = params[:opts].is_a?(Hash) ? params[:opts] : {}

      scopes = params[:opts][:scopes]
      unless scopes.nil?
        fail "Option 'scopes' can only be an Array of Strings that are one of public, private or a space-xxxx id." unless scopes.is_a?(Array) && scopes.all? { |s| s == 'public' || s == 'private' || s =~ /^space-(\d+)$/ }
      end

      classes = params[:opts][:classes]
      unless classes.nil?
        fail "Option 'classes' can be undefined or an array of strings" unless classes.is_a?(Array) && classes.all? { |k| k.is_a?(String) }
      end

      scoped_items = lambda do |scoped_item, scopes_override = false|
        unless scopes.nil?
          scope_query = scopes_override ? scopes_override : { scope: scopes }
          scoped_item = scoped_item.where(scope_query)
        end
        scoped_item = if params[:opts][:editable]
          scoped_item.editable_by(@context)
        else
          scoped_item.accessible_by(@context)
        end

        return scoped_item.to_a
      end

      allow_klass = lambda do |klass|
        return classes.nil? || classes.include?(klass)
      end

      related = []
      case item.klass
      when "file"
        related.push(*scoped_items.call(item.notes.real_notes)) if allow_klass.call("note")
        related.push(*scoped_items.call(item.comparisons)) if allow_klass.call("comparison")
        if item.parent_type == "Job"
          related.push(*scoped_items.call(Job.where(id: item.parent_id))) if allow_klass.call("job")
        end
      when "note", "answer", "discussion"
        if item.klass == "discussion"
          scopes_override = !scopes.nil? ? { notes: { scope: scopes } } : false
          related.push(*scoped_items.call(item.answers.joins(:note), scopes_override)) if allow_klass.call("answer")
        end
        note = if item.klass != "note"
          item.note
        else
          item
        end
        related.push(*scoped_items.call(note.comparisons)) if allow_klass.call("comparison")
        related.push(*scoped_items.call(note.real_files)) if allow_klass.call("file")
        related.push(*scoped_items.call(note.apps)) if allow_klass.call("app")
        related.push(*scoped_items.call(note.jobs)) if allow_klass.call("job")
        related.push(*scoped_items.call(note.assets)) if allow_klass.call("asset")
      when "app"
        related.push(*scoped_items.call(item.notes.real_notes)) if allow_klass.call("note")
        related.push(*scoped_items.call(item.jobs)) if allow_klass.call("job")
        related.push(*scoped_items.call(item.assets)) if allow_klass.call("asset")
      when "job"
        related.push(*scoped_items.call(App.where(id: item.app_id))) if allow_klass.call("app")
        related.push(*scoped_items.call(item.notes.real_notes)) if allow_klass.call("note")
        related.push(*scoped_items.call(item.input_files)) if allow_klass.call("file")
        related.push(*scoped_items.call(item.output_files)) if allow_klass.call("file")
      when "asset"
      when "comparison"
        related.push(*scoped_items.call(item.notes.real_notes)) if allow_klass.call("file")
        related.push(*scoped_items.call(item.user_files)) if allow_klass.call("file")
      when "license"
      when "space"
      when "workflow"
        related.push(*scoped_items.call(item.apps)) if allow_klass.call("app")
        related.push(*scoped_items.call(item.jobs)) if allow_klass.call("job")
      else
        fail "Unknown class #{item.klass}"
      end

      related = related.uniq.map { |o| describe_for_api(o, params[:opts][:describe]) }
      render json: related
    else
      fail "You do not have permission to access #{id}"
    end
  end

  # Inputs:
  #
  # states (array of strings; optional): the file state/s to be returned "closed", "closing", and/or "open"
  # scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes, each of which has these fields:
  # uid (string): the file's unique id (file-xxxxxx)
  # name (string): the filename
  # scopes (string): file scope, "public" or "private" or "space-xxxx"
  # path (string): file_path of the file
  #
  def list_files
    User.sync_files!(@context)

    files = if params[:editable]
      UserFile.real_files.editable_by(@context).accessible_by_private
    else
      UserFile.real_files.accessible_by(@context)
    end

    if params[:scopes].present?
      check_scope!
      files = files.where(scope: params[:scopes])
    end

    if params[:states].present?
      fail "Invalid states" unless params[:states].is_a?(Array) && params[:states].all? { |state| %w(closed closing open).include?(state) }
      files = files.where(state: params["states"])
    end

    count = files.count if params[:offset] == 0

    if params[:limit] && params[:offset]
      files = files.limit(params[:limit]).offset(params[:offset])
    end

    result = files.eager_load(:license, user: :org).order(id: :desc).map do |file|
      describe_for_api(file, params[:describe])
    end

    render json: params[:offset] == 0 ? { objects: result, count: count } : result
  end

  # Inputs
  #
  # scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  # note_types (Array, optional): array of valid note_types e.g. ["Note", "Answer", "Discussion"]
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_notes
    notes = if params[:editable]
      Note.editable_by(@context).where.not(title: nil).accessible_by_private
    else
      Note.accessible_by(@context).where.not(title: nil)
    end

    if params[:scopes].present?
      check_scope!
      notes = notes.where(scope: params[:scopes])
    end

    if params[:note_types].present?
      fail "Param note_types can only be an Array of Strings containing 'Note', 'Answer', or 'Discussion'" unless params[:note_types].is_a?(Array) && params[:note_types].all? { |type| %w(Note Answer Discussion).include?(type) }

      note_types = params[:note_types].map { |type| type == "Note" ? nil : type }
      notes = notes.where(note_type: note_types)
    end

    result = notes.order(id: :desc).map do |note|
      if note.note_type == "Discussion"
        note = note.discussion
      elsif note.note_type == "Answer"
        note = note.answer
      end
      describe_for_api(note, params[:describe])
    end

    render json: result
  end

  # Inputs
  #
  # scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_comparisons
    # TODO: sync comparisons?
    comparisons = if params[:editable]
      Comparison.editable_by(@context).accessible_by_private
    else
      Comparison.accessible_by(@context)
    end

    if params[:scopes].present?
      check_scope!
      comparisons = comparisons.where(scope: params[:scopes])
    end

    result = comparisons.order(id: :desc).map do |comparison|
      describe_for_api(comparison, params[:describe])
    end

    render json: result
  end

  # Inputs
  #
  # scopes (Array, optional): array of valid scopes on the App e.g. ["private", "public", "space-1234"] or leave blank for all
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_apps
    app_series = if params[:editable]
      AppSeries.editable_by(@context).accessible_by_private
    else
      AppSeries.accessible_by(@context)
    end

    app_series = app_series.eager_load(:latest_revision_app, :latest_version_app).order(id: :desc)
    apps = app_series.map { |series| series.latest_accessible(@context) }.compact

    # The scope applies to the App and not the AppSeries
    if params[:scopes].present?
      check_scope!
      apps = apps.select { |app| params[:scopes].include?(app.scope) }
    end

    result = apps.map do |app|
      describe_for_api(app, params[:describe])
    end

    render json: result
  end

  # Inputs
  #
  # scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_jobs
    jobs = if params[:editable]
      Job.editable_by(@context).accessible_by_private
    else
      Job.accessible_by(@context)
    end

    if params[:scopes].present?
      check_scope!
      jobs = jobs.where(scope: params[:scopes])
    end

    result = jobs.eager_load(user: :org).order(id: :desc).map do |job|
      describe_for_api(job, params[:describe])
    end

    render json: result
  end

  # Inputs
  #
  # ids (array:string, optional): the dxids of the assets
  # scopes (Array, optional): array of valid scopes e.g. ["private", "public", "space-1234"] or leave blank for all
  # editable (Boolean, optional): if filtering for only editable_by the context user, otherwise accessible_by
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # An array of hashes
  #
  def list_assets
    # Refresh state of assets, if needed
    User.sync_assets!(@context)

    ids = params[:ids]
    assets = if params[:editable]
      Asset.closed.editable_by(@context).accessible_by_private
    else
      Asset.closed.accessible_by(@context)
    end

    unless ids.nil?
      fail "The 'ids' parameter needs to be an Array of String asset ids" unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) }
      assets = assets.where(uid: ids)
    end

    if params[:scopes].present?
      check_scope!
      assets = assets.where(scope: params[:scopes])
    end

    result = assets.order(:name).map do |asset|
      describe_for_api(asset, params[:describe])
    end

    unless ids.nil?
      # This would happen if an asset becomes inaccessible
      # For now silently drop the asset -- allows for asset deletion
      # raise unless ids.size == result.size
    end

    render json: result
  end

  def list_workflows
    workflow_series = if params[:editable]
      WorkflowSeries.editable_by(@context).accessible_by_private
    else
      WorkflowSeries.accessible_by(@context)
    end

    workflow_series = workflow_series.eager_load(:latest_revision_workflow).order(id: :desc)
    workflows = workflow_series.map { |series| series.latest_accessible(@context) }.compact

    if params[:scopes].present?
      check_scope!
      workflows = workflows.select { |workflow| params[:scopes].include?(workflow.scope) }
    end

    result = workflows.map do |workflow|
      describe_for_api(workflow, params[:describe])
    end

    render json: result
  end

  # Inputs
  #
  # uid (string, required): the uid of the item to describe
  # describe (object, optional)
  #     fields (array, optional):
  #         Array containing field name [field_1, field_2, ...]
  #         to indicate which object fields to include
  #     include (object, optional)
  #         license (boolean, optional)
  #         user (boolean, optional)
  #         org (boolean, optional)
  #         all_tags_list (boolean, optional)
  #
  # Outputs:
  #
  # id (integer)
  # uid (string)
  # describe (object)
  #
  def describe
    # Item id should be a string
    uid = params[:uid]
    fail "The parameter 'uid' should be of type String" unless uid.is_a?(String) && uid != ""

    item = item_from_uid(uid)

    render json: describe_for_api(item, params[:describe])
  end

  # Inputs:
  #
  # license_ids (array of license ids, required, nonempty): licenses to accept
  #
  # Outputs:
  #
  # accepted_licenses: license_ids (same as input)
  #
  def accept_licenses
    license_ids = params["license_ids"]
    fail "License license_ids needs to be an Array of Integers" unless license_ids.is_a?(Array) && license_ids.all? do |license_id|
                                                                          license_id.is_a?(Numeric) && (license_id.to_i == license_id)
                                                                        end && !license_ids.empty?
    license_ids.uniq!
    fail "Some license_ids do not exist" unless License.where(id: license_ids).count == license_ids.count

    AcceptedLicense.transaction do
      license_ids.each do |license_id|
        AcceptedLicense.find_or_create_by(license_id: license_id, user_id: @context.user_id)
      end
    end

    render json: { accepted_licenses: license_ids }
  end

  # Use this to associate multiple items to a license
  #
  # Inputs
  #
  # license_id (integer, required)
  # items_to_license (Array[string], required): array of object uids
  #
  # Outputs:
  #
  # license_id (integer)
  # items_licensed (Array[string]): array of object uids attached to license
  #
  def license_items
    license_id = params["license_id"]
    fail "License license_id needs to be an Integer" unless license_id.is_a?(Numeric) && (license_id.to_i == license_id)

    # Check if the license exists and is editable by the user. Throw 404 if otherwise.
    License.editable_by(@context).find(license_id)

    items_to_license = params["items_to_license"]
    fail "License items_o_license needs to be an Array of Strings" unless items_to_license.is_a?(Array) && items_to_license.all? do |item|
                                                                             item.is_a?(String)
                                                                           end

    items_licensed = []
    LicensedItems.transaction do
      items_to_license.each do |item_uid|
        item = item_from_uid(item_uid)
        if item.editable_by(@context) && %w(asset file).include?(item.klass)
          items_licensed << LicensedItems.find_or_create_by(license_id: license_id, licenseable: item).uid
        end
      end
    end

    render json: { license_id: license_id, items_licensed: items_licensed }
  end

  # Inputs:
  #
  # name (string, required, nonempty)
  # description (string, optional)
  #
  # Outputs:
  #
  # id (string, "file-xxxx")
  #
  def create_file
    name = params[:name]
    fail "File name needs to be a non-empty String" unless name.is_a?(String) && name != ""

    description = params["description"]
    unless description.nil?
      fail "File description needs to be a String" unless description.is_a?(String)
    end

    folder = Folder.editable_by(@context).find_by(id: params[:folder_id])

    project = @context.user.private_files_project
    dxid = DNAnexusAPI.new(@context.token).call("file", "new", "name": params[:name], "project": project)["id"]

    file = UserFile.transaction do
      UserFile.create!(
        dxid: dxid,
        project: project,
        name: name,
        state: "open",
        description: description,
        user_id: @context.user_id,
        parent: @context.user,
        scope: 'private',
        parent_folder_id: folder.try(:id)
      )
    end

    render json: { id: file.uid }
  end

  def create_challenge_card_image
    return unless @context.can_administer_site? || @context.challenge_admin?

    name = params[:name]
    fail "File name needs to be a non-empty String" unless name.is_a?(String) && name != ""

    description = params["description"]
    unless description.nil?
      fail "File description needs to be a String" unless description.is_a?(String)
    end

    project = CHALLENGE_BOT_PRIVATE_FILES_PROJECT
    dxid = DNAnexusAPI.new(CHALLENGE_BOT_TOKEN).call("file", "new", "name": params[:name], "project": CHALLENGE_BOT_PRIVATE_FILES_PROJECT)["id"]

    file = UserFile.create!(
      dxid: dxid,
      project: project,
      name: name,
      state: "open",
      description: description,
      user_id: User.challenge_bot.id,
      parent: User.challenge_bot,
      scope: 'private'
    )

    render json: { id: file.uid }
  end

  # Inputs:
  #
  # name (string, required, nonempty)
  # description (string, optional)
  #
  # Outputs:
  #
  # id (string, "file-xxxx")
  #
  def create_challenge_resource
    return unless @context.challenge_admin?

    challenge = Challenge.find_by!(id: params[:challenge_id])
    unless challenge.editable_by?(@context)
      fail "Challenge cannot be modified by current user."
    end

    name = params[:name]
    fail "File name needs to be a non-empty String" unless name.is_a?(String) && name != ""

    description = params["description"]
    unless description.nil?
      fail "File description needs to be a String" unless description.is_a?(String)
    end

    project = CHALLENGE_BOT_PRIVATE_FILES_PROJECT
    dxid = DNAnexusAPI.new(CHALLENGE_BOT_TOKEN).call("file", "new", "name": params[:name], "project": CHALLENGE_BOT_PRIVATE_FILES_PROJECT)["id"]
    challenge_bot = User.challenge_bot

    UserFile.transaction do
      file = UserFile.create!(
        dxid: dxid,
        project: project,
        name: name,
        state: "open",
        description: description,
        user_id: challenge_bot.id,
        parent: challenge_bot,
        scope: 'private'
      )

      ChallengeResource.create!(
        challenge_id: challenge.id,
        user_file_id: file.id,
        user_id: @context.user_id
      )

      render json: { id: file.uid }
    end
  end

  def create_resource_link
    file = UserFile.where(user_id: User.challenge_bot.id).find_by_uid!(params[:id])
    resource = ChallengeResource.find_by!(user_id: @context.user_id, challenge_id: params[:challenge_id], user_file_id: file.id)

    unless resource.editable_by?(@context)
      fail "Challenge resource cannot be modified by current user."
    end

    # Refresh state of file, if needed
    if file.state != "closed"
      User.sync_challenge_bot_files!(@context)
      file.reload
    end

    if file.state != "closed"
      render json: {
        error: "Files can only be downloaded if they are in the 'closed' state",
        errorType: "FileNotClosed",
      }
      return
    end

    # FIXME:
    # The API warns against storing the url as it may contain
    # auth information that we don't want to expose
    # So we may have to store a reference to the file and generate
    # a shorter duration url each time it is rendered

    url = DNAnexusAPI.new(CHALLENGE_BOT_TOKEN).generate_permanent_link(file)

    resource.update_attributes(url: url)

    render json: { id: file.uid, url: url }
  end

  def get_file_link
    error = false

    # Allow assets as well, thought not currently exposed in the UI
    file = UserFile.accessible_by(@context).find_by_uid!(params[:id])

    # Refresh state of file, if needed
    if file.state != "closed"
      if file.parent_type == "Asset"
        User.sync_asset!(@context, file.id)
      else
        if file.created_by_challenge_bot? && (@context.can_administer_site? || @context.challenge_admin?)
          User.sync_challenge_file!(file.id)
        else
          User.sync_file!(@context, file.id)
        end
      end
      file.reload
    end

    if file.state != "closed"
      error = "Files can only be downloaded if they are in the 'closed' state"
      errorType = "FileNotClosed"
    elsif file.license.present? && !file.licensed_by?(@context)
      error = "You must accept the license before you can get the download link"
      errorType = "LicenseError"
    else
      # FIXME:
      # The API warns against storing the url as it may contain
      # auth information that we don't want to expose
      # So we may have to store a reference to the file and generate
      # a shorter duration url each time it is rendered

      token = if file.created_by_challenge_bot? && (@context.can_administer_site? || @context.challenge_admin?)
        CHALLENGE_BOT_TOKEN
      else
        @context.token
      end

      opts = { project: file.project, preauthenticated: true, filename: file.name, duration: 300 }
      url = DNAnexusAPI.new(token).call(file.dxid, "download", opts)["url"]
    end

    if error
      render json: { error: error, errorType: errorType }
    else
      render json: { id: file.uid, url: url }
    end
  end

  # Inputs:
  #
  # name (string, required, nonempty)
  # description (string, optional)
  # paths (array:string, required)
  #
  # Outputs:
  #
  # id (string, "file-xxxx")
  #
  def create_asset
    asset = AssetService.create(@context, params)

    render json: { id: asset.uid }
  end

  # Inputs:
  #
  # size (int, required)
  # md5 (string, required)
  # index (int, required)
  # id (string, required)
  #
  # Outputs:
  #
  # url (string, where HTTP PUT must be performed)
  # expires (int, timestamp)
  # headers (hash of string key/values, headers must be given to HTTP PUT)
  #
  def get_upload_url
    url_service = UploadUrlFetcher.new(@context, params[:id])

    result = url_service.fetch_url(params)

    render json: result
  end

  # Inputs:
  #
  # id (string, required)
  #
  # Outputs: nothing (empty hash)
  #
  def close_file
    id = params[:id]
    fail "id needs to be a non-empty string" unless id.is_a?(String) && id != ""

    file = UserFile.where(parent_type: "User").find_by_uid!(id)
    token = @context.token
    if file.user_id != @context.user_id
      if file.created_by_challenge_bot? && (@context.user.can_administer_site? || @context.user.is_challenge_admin?)
        token = CHALLENGE_BOT_TOKEN
      else
        fail "The current user does not have access to the file."
      end
    end

    if file.state == "open"
      DNAnexusAPI.new(token).call(file.dxid, "close")
      UserFile.transaction do
        # Must recheck inside the transaction
        file.reload
        if file.state == "open"
          file.state = "closing"
          file.save!
        end
      end
    end

    render json: {}
  end

  # Inputs:
  #
  # id (string, required)
  #
  # Outputs: nothing (empty hash)
  #
  def close_asset
    asset_uid = params[:id]

    if !asset_uid.is_a?(String) || asset_uid.empty?
      fail "id needs to be a non-empty String"
    end

    AssetService.close(@context, uid: asset_uid)

    render json: {}
  end

  # Inputs
  #
  # id (string, required): the dxid of the app to run
  # name (string, required): the name of the job
  # inputs (hash, required): the inputs
  # instance_type (string, optional): override of the default instance type
  #
  # Outputs
  #
  # id (string): the dxid of the resulting job
  #
  def run_app
    # Parameter 'id' should be of type String
    id = params[:id]
    fail "App ID is not a string" unless id.is_a?(String) && id != ""

    # Name should be a nonempty string
    name = params[:name]
    fail "Name should be a non-empty string" unless name.is_a?(String) && name != ""

    # Inputs should be a hash (more checks later)
    inputs = params["inputs"]
    fail "Inputs should be a hash" unless inputs.is_a?(Hash)

    # App should exist and be accessible
    @app = App.accessible_by(@context).find_by_uid!(id)

    # Check if asset licenses have been accepted
    fail "Asset licenses must be accepted" unless @app.assets.all? { |a| !a.license.present? || a.licensed_by?(@context) }

    space_id = params[:space_id]
    if space_id
      fail "Invalid space_id" unless @app.can_run_in_space?(@context.user, space_id)
    end
    space = Space.find_by_id(space_id)
    # Inputs should be compatible
    # (The following also normalizes them)
    input_info = input_spec_preparer.run(@app, inputs, space.try(:accessible_scopes))

    fail input_spec_preparer.first_error unless input_spec_preparer.valid?

    run_instance_type = params[:instance_type]

    # User can override the instance type
    if run_instance_type
      fail "Invalid instance type selected" unless Job::INSTANCE_TYPES.key?(params["instance_type"]) # Checks also that it's a string
    end

    job = job_creator.create(
      app: @app,
      name: name,
      input_info: input_info,
      run_instance_type: run_instance_type,
      scope: space.try(:uid),
    )
    SpaceEventService.call(space_id, @context.user_id, nil, job, :job_added) if space && space.review?

    render json: { id: job.uid }
  end

  # Inputs
  #
  # app_id
  #
  # Outputs
  #
  # json (string, only on success): spec, ordered_assets, and packages of the specified app
  def get_app_spec
    # App should exist and be accessible
    app = App.accessible_by(@context).find_by_uid(params[:id])
    fail "Invalid app id" if app.nil?

    render json: { spec: app.spec, assets: app.ordered_assets, packages: app.packages }
  end

  # Inputs
  #
  # app_id
  #
  # Outputs
  #
  # plain text (string, only on success): code for the specified app
  def get_app_script
    # App should exist and be accessible
    app = App.accessible_by(@context).find_by_uid(params[:id])
    fail "Invalid app id" if app.nil?

    render plain: app.code
  end

  def export_app
    # App should exist and be accessible
    app = App.accessible_by(@context).find_by_uid(params[:id])
    fail "Invalid app id" if app.nil?

    # Assets should be accessible and licenses accepted
    fail "One or more assets are not accessible by the current user." if app.assets.accessible_by(@context).count != app.assets.count
    fail "One or more assets need to be licensed. Please run the app first in order to accept the licenses." if app.assets.any? { |a| a.license.present? && !a.licensed_by?(@context) }

    render json: { content: app.to_docker(@context.token) }
  end

  def share_with_fda
    app = App.find(params[:id])
    api = DNAnexusAPI.new(@context.token)
    dev_group = Setting.review_app_developers_org

    data = api.call(app.dxid, 'addDevelopers', "developers": [dev_group])
    app.dev_group = dev_group
    app.save!

    respond_to do |r|
      r.json do
        render json: { "app_id": app.id, data: data, dxuser: @context.user.dxuser, owner: app.user.dxuser }
      end
    end
  end

  # Inputs
  #
  # prefix (string, required): the prefix to search for
  #
  # Outputs:
  #
  # uids (array:string): the matching asset uids
  #
  def search_assets
    prefix = params[:prefix]

    if !prefix.is_a?(String) || prefix.size < 3
      fail "Prefix should be a String of at least 3 characters"
    end

    assets = Asset.closed.
      accessible_by(@context).
      order(:name).
      with_search_keyword(prefix).
      select(:uid).
      distinct.
      limit(ASSETS_SEARCH_LIMIT)

    render json: { uids: assets.map(&:uid) }
  end

  # Use this to add multiple items of the same type to a note
  # or multiple notes to an item
  # Inputs
  #
  # note_uids (Array[String], required): array of note, discussion, answer uids
  # item (Array[Object], required): array of items with id, type
  #     item.type (String): type of string from App, Comparison, Job, or UserFile
  #
  # Outputs:
  #
  # notes_added (Array[String])
  # items_added (Array[Integer])
  #
  def attach_to_notes
    note_uids = params[:note_uids]
    fail "Parameter 'note_uids' need to be an Array of Note, Answer, or Discussion uids" unless note_uids.is_a?(Array) && note_uids.all? { |uid| uid =~ /^(note|discussion|answer)-(\d+)$/ }

    items = params[:items]
    fail "Items need to be an array of objects with id and type (one of App, Comparison, Job, or UserFile)" unless items.is_a?(Array) && items.all? { |item| item[:id].is_a?(Numeric) && item[:type].is_a?(String) && %w(App Comparison Job UserFile).include?(item[:type]) }

    notes_added = {}
    items_added = {}
    Note.transaction do
      note_uids.each do |note_uid|
        note_item = item_from_uid(note_uid)
        next unless !note_item.nil? && note_item.editable_by?(@context)
        items.each do |item|
          item[:type] = item[:type].present? ? item[:type] : type_from_classname(item[:className])
          note_item.attachments.find_or_create_by(item_id: item[:id], item_type: item[:type])
          items_added["#{item[:type]}-#{item[:id]}"] = true
        end
        notes_added[note_uid] = true
        note_item.save
      end
    end

    render json: {
      notes_added: notes_added,
      items_added: items_added,
    }
  end

  # Inputs
  #
  # id (integer, required): the id of the submission to be updated
  # title (string): the updated submission title
  # content (string): the updated submission description
  #
  # Outputs:
  # id: the submission id
  #
  def update_submission
    id = params[:id].to_i
    fail "id needs to be an Integer" unless id.is_a?(Integer)

    title = params[:title]
    fail "title needs to be a String" unless title.is_a?(String)

    content = params[:content] || ""
    fail "content needs to be a String" unless content.is_a?(String)

    submission = nil
    Submission.transaction do
      submission = Submission.editable_by(@context).find(params[:id])
      fail "no submission found" unless submission
      submission.update!(desc: content)
      submission.job.update!(name: title)
    end

    render json: {
      id: submission.id,
    }
  end

  # Inputs
  #
  # id (integer, required): the id of the note to be updated
  # title (string): the updated note title
  # content (string): the updated note content
  # attachments_to_save (string array): an array of one or more object uids to be "ensured"
  # attachments_to_delete (string array): an array of one or more object uids to be removed
  #
  # Outputs:
  # id: the note id
  # path (string): the human readable path of the note (which could have changed if the title changed)
  #
  def update_note
    id = params[:id].to_i
    fail "id needs to be an Integer" unless id.is_a?(Integer)

    title = params[:title]
    fail "title needs to be a String" unless title.is_a?(String)

    content = params[:content] || ""
    fail "content needs to be a String" unless content.is_a?(String)

    attachments_to_save = params[:attachments_to_save] || []
    fail "attachments_to_save needs to be an array" unless attachments_to_save.is_a?(Array)

    attachments_to_delete = params[:attachments_to_delete] || []
    fail "attachments_to_delete neeeds to be an array" unless attachments_to_delete.is_a?(Array)

    note = nil
    Note.transaction do
      note = Note.find_by!(id: params[:id])
      fail '' unless note.editable_by?(@context)

      attachments_to_save.each do |uid|
        item = item_from_uid(uid)
        note.attachments.find_or_create_by(item: item)
      end

      attachments_to_delete.each do |uid|
        item = item_from_uid(uid)
        note.attachments.where(item: item).destroy_all
      end

      note.update!(title: title, content: content)
    end

    render json: {
      id: note.id,
      path: note_path(note),
    }
  end

  # Inputs
  #
  # uid (string, required): the uid of the item to upvote
  # vote_scope (string, optional)
  #
  # Outputs:
  # uid (string): the uid of the item
  # upvote_count (integer): latest upvote count for item
  #
  def upvote
    uid = params[:uid]
    fail "Item uid needs to be a non-empty string" unless uid.is_a?(String) && uid != ""

    vote_scope = params[:vote_scope]

    item = item_from_uid(uid)
    if item.accessible_by?(@context) && ["app-series", "discussion", "answer", "note", "comparison", "job", "file", "asset"].include?(item.klass)
      if vote_scope.present?
        # Special treatment for appathon vote_scope
        if vote_scope =~ /^(appathon)-(\d+)$/
          appathon = item_from_uid(vote_scope, Appathon)
          fail "#{uid} is not accessible by you in this scope" unless appathon.followed_by?(@context.user)
        end
        item.liked_by(@context.user, vote_scope: vote_scope)
        upvote_count = item.get_upvotes(vote_scope: vote_scope).size
      else
        item.liked_by(@context.user)
        upvote_count = item.get_upvotes.size
      end
      render json: {
        uid: uid,
        upvote_count: upvote_count,
      }
    else
      fail "#{uid} is not accessible by you"
    end
  end

  # Inputs
  #
  # uid (string, required): the uid of the item to remove an upvote
  # vote_scope (string, optional)
  #
  # Outputs:
  # uid (string): the uid of the item
  # upvote_count (integer): latest upvote count for item
  #
  def remove_upvote
    uid = params[:uid]
    fail "Item uid needs to be a non-empty string" unless uid.is_a?(String) && uid != ""

    vote_scope = params[:vote_scope]

    item = item_from_uid(uid)
    if item.accessible_by?(@context) && ["app-series", "discussion", "answer", "note", "comparison", "job", "file", "asset"].include?(item.klass)
      if vote_scope.present?
        # Special treatment for appathon vote_scope
        if vote_scope =~ /^(appathon)-(\d+)$/
          appathon = item_from_uid(vote_scope, Appathon)
          fail "#{uid} is not accessible by you in this scope" unless appathon.followed_by?(@context.user)
        end
        item.unliked_by(@context.user, vote_scope: vote_scope)
        upvote_count = item.get_upvotes(vote_scope: vote_scope).size
      else
        item.unliked_by(@context.user)
        upvote_count = item.get_upvotes.size
      end
      render json: {
        uid: uid,
        upvote_count: upvote_count,
      }
    else
      fail "#{uid} is not accessible by you"
    end
  end

  # Inputs
  #
  # followable_uid (string, required): the uid of the item to follow
  #
  # Outputs:
  # followable_uid (string): the uid of the item followed
  # follower_uid (string): the uid of the follower
  # follow_count (integer): latest count of follows on the followable item
  #
  def follow
    followable_uid = params["followable_uid"]
    fail "Followable uid needs to be a non-empty string" unless followable_uid.is_a?(String) && followable_uid != ""

    followable = item_from_uid(followable_uid)
    follower = @context.user
    if followable.accessible_by?(@context) && %w(discussion challenge).include?(followable.klass)
      follower.follow(followable)
      render json: {
        followable_uid: followable_uid,
        follower_uid: follower.uid,
        follow_count: followable.followers_by_type_count(follower.class.name),
      }
    else
      fail "You do not have permission to follow this object"
    end
  end

  # Inputs
  #
  # follow_uid (string, required): the uid of the item to unfollow
  #
  # Outputs:
  # follow_uid (string): the uid of the item unfollowed
  # follower_uid (string): the uid of the follower
  # follow_count (integer): latest count of follows on the followable item
  #
  def unfollow
    followable_uid = params["followable_uid"]
    fail "Followable uid needs to be a non-empty string" unless followable_uid.is_a?(String) && followable_uid != ""

    followable = item_from_uid(followable_uid)
    follower = @context.user
    if followable.accessible_by?(@context) && ["discussion"].include?(followable.klass)
      follower.stop_following(followable)
      render json: {
        followable_uid: followable_uid,
        follower_uid: follower.uid,
        follow_count: followable.followers_by_type_count(follower.class.name),
      }
    else
      fail "You do not have permission to unfollow this object"
    end
  end

  def update_time_zone
    current_user.update_time_zone(params[:time_zone])
    render json: { success: true }
  end

  protected

  def input_spec_preparer
    @input_spec_preparer ||= InputSpecPreparer.new(@context)
  end

  def job_creator
    @job_creator ||= JobCreator.new(
      api: DNAnexusAPI.new(@context.token),
      context: @context,
      user: @context.user,
      project: @context.user.private_files_project
    )
  end

  def check_scope!
    condition = params[:scopes].is_a?(Array)
    condition &&= params[:scopes].all? { |scope| scope == 'public' || scope == 'private' || scope =~ /^space-(\d+)$/ }
    fail(t('api.errors.invalid_scope')) unless condition
  end

  def validate_get_upload_url
    size = params[:size]
    fail "Parameter 'size' needs to be a Fixnum" unless size.is_a?(Fixnum)

    md5 = params[:md5]
    fail "Parameter 'md5' needs to be a String" unless md5.is_a?(String)

    index = params[:index]
    fail "Parameter 'index' needs to be a Fixnum" unless index.is_a?(Fixnum)

    id = params[:id]
    if !id.is_a?(String) || id.empty?
      fail "Parameter 'id' needs to be a non-empty String"
    end
  end

  def validate_create_asset
    name = params[:name]

    if !name.is_a?(String) || name.empty?
      fail "Asset name needs to be a non-empty String"
    end

    if !name.match(/\w+\.tar(\.gz)?$/)
      fail "Asset name should end with .tar or .tar.gz"
    end

    description = params["description"]

    unless description.is_a?(String)
      fail "Asset description needs to be a String"
    end

    paths = params["paths"]

    if !paths.is_a?(Array) || paths.empty? || paths.size >= 100_000
      fail "Asset paths needs to be a non-empty Array less than 100000 size"
    end

    if paths.any?{ |path| !path.is_a?(String) || path.empty? || path.size >= 4096 }
      fail "Asset path should be a non-empty String of size less than 4096"
    end
  end
end
