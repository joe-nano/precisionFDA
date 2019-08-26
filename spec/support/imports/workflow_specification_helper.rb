module Imports
  module WorkflowSpecificationHelper
    def specification
      { input_spec:
        { stages:
          [
            {
              name: "app-776-first-step-1",
              prev_slot: nil,
              next_slot: "stage-ec9qciiclc0000",
              slotId: "stage-lnuqrt1wxs0000",
              app_dxid: "app-FXKBg3803PFFYJjz11BgJ4b4",
              app_uid: "app-FXKBg3803PFFYJjz11BgJ4b4-1",
              inputs: [
                { "name" => "input_file_param_1",
                  "class" => "file",
                  "parent_slot" => "stage-lnuqrt1wxs0000",
                  "stageName" => "app-776-first-step-1",
                  "values" => { "id" => nil, "name" => nil },
                  "requiredRunInput" => true,
                  "optional" => false,
                  "label" => "" },
                { "name" => "input_string_param_1",
                  "class" => "string",
                  "parent_slot" => "stage-lnuqrt1wxs0000",
                  "stageName" => "app-776-first-step-1",
                  "values" => { "id" => nil, "name" => nil },
                  "requiredRunInput" => true,
                  "optional" => false,
                  "label" => "" },
              ],
              outputs: [
                { "name" => "output_file_param_1",
                  "class" => "file",
                  "parent_slot" => "stage-lnuqrt1wxs0000",
                  "stageName" => "app-776-first-step-1",
                  "values" => { "id" => "stage-ec9qciiclc0000", "name" => "app-776-second-step-1" },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
                { "name" => "output_string_param_1",
                  "class" => "string",
                  "parent_slot" => "stage-lnuqrt1wxs0000",
                  "stageName" => "app-776-first-step-1",
                  "values" => { "id" => "stage-ec9qciiclc0000", "name" => "app-776-second-step-1" },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
              ],
              instanceType: "baseline-8",
              stageIndex: nil,
            },
            {
              name: "app-776-second-step-1",
              prev_slot: "stage-lnuqrt1wxs0000",
              next_slot: nil,
              slotId: "stage-ec9qciiclc0000",
              app_dxid: "app-FXKBjg807jkfZKYq126yx61f",
              app_uid: "app-FXKBjg807jkfZKYq126yx61f-1",
              inputs: [
                { "name" => "input_file_param_1",
                  "class" => "file",
                  "parent_slot" => "stage-ec9qciiclc0000",
                  "stageName" => "app-776-second-step-1",
                  "values" => { "id" => "stage-lnuqrt1wxs0000", "name" => "output_file_param_1" },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
                { "name" => "input_string_param_1",
                  "class" => "string",
                  "parent_slot" => "stage-ec9qciiclc0000",
                  "stageName" => "app-776-second-step-1",
                  "values" => { "id" => "stage-lnuqrt1wxs0000", "name" => "output_string_param_1" },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
              ],
              outputs: [
                { "name" => "output_file_param_1",
                  "class" => "file",
                  "parent_slot" => "stage-ec9qciiclc0000",
                  "stageName" => "app-776-second-step-1",
                  "values" => { "id" => nil, "name" => nil },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
                { "name" => "output_string_param_1",
                  "class" => "string",
                  "parent_slot" => "stage-ec9qciiclc0000",
                  "stageName" => "app-776-second-step-1",
                  "values" => { "id" => nil, "name" => nil },
                  "requiredRunInput" => false,
                  "optional" => false,
                  "label" => "" },
              ],
              instanceType: "baseline-8",
              stageIndex: nil,
            },
          ] },
        output_spec: { stages: [] } }
    end
  end
end