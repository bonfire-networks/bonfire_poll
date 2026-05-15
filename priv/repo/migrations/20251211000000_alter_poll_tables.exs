defmodule Bonfire.Poll.Repo.Migrations.AlterPollTables do
  @moduledoc false
  use Ecto.Migration

  def up do
    # Added 2025-12-11 — missing from original create migration
    alter table(:bonfire_poll_question) do
      add_if_not_exists(:voting_format, :string,
        null: false,
        default:
          Application.get_env(:bonfire_poll, :default_voting_format, "weighted_multiple")
      )
    end

    # vote_weight was changed to nullable shortly after initial migration
    alter table(:bonfire_poll_vote) do
      modify(:vote_weight, :integer, null: true)
    end
  end

  def down do
    alter table(:bonfire_poll_question) do
      remove_if_exists(:voting_format, :string)
    end

    alter table(:bonfire_poll_vote) do
      modify(:vote_weight, :integer, null: false)
    end
  end
end
