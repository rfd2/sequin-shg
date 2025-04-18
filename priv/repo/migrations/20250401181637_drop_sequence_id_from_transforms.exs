defmodule Sequin.Repo.Migrations.DropSequenceIdFromTransforms do
  use Ecto.Migration

  @config_schema Application.compile_env(:sequin, [Sequin.Repo, :config_schema_prefix])

  def up do
    alter table(:transforms, prefix: @config_schema) do
      remove :sequence_id
    end
  end

  def down do
    alter table(:transforms, prefix: @config_schema) do
      add :sequence_id, references(:sequences, on_delete: :delete_all, prefix: @config_schema)
    end
  end
end
