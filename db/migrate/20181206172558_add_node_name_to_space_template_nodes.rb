class AddNodeNameToSpaceTemplateNodes < ActiveRecord::Migration[4.2]
  def change
    add_column :space_template_nodes, :node_name, :string
  end
end
