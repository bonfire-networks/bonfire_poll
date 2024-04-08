defmodule Bonfire.Poll.Vote do
  use Needle.Pointable,
    otp_app: :bonfire_poll,
    table_id: "7S0C10CRAT1CDEM0S0FC0NSENT",
    source: "bonfire_poll_vote"

  require Needle.Changesets
  alias Bonfire.Poll.Vote
  alias Bonfire.Data.Edges.Edge
  import Ecto.Changeset
  use Arrows

  pointable_schema do
    field :vote_weight, :integer
    has_one(:edge, Edge, foreign_key: :id)
  end

  @cast [:vote_weight]

  def changeset(vote \\ %Vote{}, params)

  def changeset(vote, params),
    do:
      cast(vote, params, @cast)
      |> validate_required(@cast)
end

defmodule Bonfire.Poll.Vote.Migration do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration
  alias Bonfire.Poll.Vote

  # create_vote_table/{0,1}

  defp make_vote_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_pointable_table Bonfire.Poll.Vote do
        add :vote_weight, :integer
        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_vote_table(), do: make_vote_table([])
  defmacro create_vote_table(do: body), do: make_vote_table(body)

  # drop_vote_table/0

  def drop_vote_table(), do: drop_pointable_table(Vote)

  # migrate_vote/{0,1}

  defp mr(:up), do: make_vote_table([])

  defp mr(:down) do
    quote do: Bonfire.Poll.Vote.Migration.drop_vote_table()
  end

  defmacro migrate_vote() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mr(:up)),
        else: unquote(mr(:down))
    end
  end

  defmacro migrate_vote(dir), do: mr(dir)
end
