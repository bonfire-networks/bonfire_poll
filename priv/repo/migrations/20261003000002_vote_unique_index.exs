defmodule Bonfire.Poll.Repo.Migrations.VoteUniqueIndex do
  @moduledoc false
  use Ecto.Migration

  # Votes need a unique index (like likes, follows, etc), so a re-vote on the same choice doesn't insert a second vote edge. Remove any duplicates, keeping each voter's most recent vote on a choice (edge ids are ULIDs, so the largest is the latest), then add the index.
  def up do
    table_id =
      Bonfire.Poll.Vote.__pointers__(:table_id)
      |> Needle.ULID.dump()
      |> elem(1)
      |> Ecto.UUID.cast!()

    # deleting the pointer cascades to the vote and its edge
    execute("""
    DELETE FROM pointers_pointer WHERE id IN (
      SELECT e.id FROM bonfire_data_edges_edge e
      WHERE e.table_id = '#{table_id}'
        AND EXISTS (
          SELECT 1 FROM bonfire_data_edges_edge later
          WHERE later.table_id = e.table_id
            AND later.subject_id = e.subject_id
            AND later.object_id = e.object_id
            AND later.id > e.id
        )
    )
    """)

    Bonfire.Data.Edges.Edge.Migration.migrate_type_unique_index(:up, Bonfire.Poll.Vote)
  end

  def down do
    Bonfire.Data.Edges.Edge.Migration.migrate_type_unique_index(:down, Bonfire.Poll.Vote)
  end
end
