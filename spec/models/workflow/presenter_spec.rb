require "rails_helper"
include Imports::WorkflowHelper
include Imports::StagesHelper
include Imports::AppSpecHelper

RSpec.describe Workflow::Presenter, type: :model do
  context "when input data is json from front" do
    let(:raw) { params }
    let(:context) { Context.new(user.id, user.dxuser, SecureRandom.uuid, nil, nil) }

    before do
      params["slots"].each do |slot|
        create(:app, dxid: slot["uid"].split("-1").first, user_id: user.id, spec: app_spec)
      end
      allow_any_instance_of(Context).to receive(:logged_in?).and_return(true)
    end

    it_behaves_like "workflow_presenter"
  end

  context "when input data is cwl file" do
    let(:cwl) { IO.read(Rails.root.join("spec/support/files/workflow_import/workflow.cwl")) }
    let(:cwl_presenter) { Workflow::Cwl::Presenter.new(cwl, context) }
    let(:stages) { cwl_presenter.send(:stages_object) }
    let(:context) { Context.new(user.id, user.dxuser, SecureRandom.uuid, nil, nil) }
    let(:raw) { cwl_presenter.build }

    before do
      params["slots"].each do |slot|
        create(:app, dxid: slot["uid"].split("-1").first, user_id: user.id, spec: app_spec)
      end
      allow_any_instance_of(Context).to receive(:logged_in?).and_return(true)
      allow(stages.slot_objects["app-776-first-step-1"]).to receive(:slot_id)
        .and_return(params["slots"].first["slotId"])
      allow(stages.slot_objects["app-776-second-step-1"]).to receive(:slot_id)
        .and_return(params["slots"].second["slotId"])
    end

    it_behaves_like "workflow_presenter"
  end
end
