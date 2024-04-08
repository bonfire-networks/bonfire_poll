defmodule Bonfire.Poll.Question do
  use Needle.Pointable,
    otp_app: :bonfire_poll,
    table_id: "7VEST10NP011SVRVEYPR0P0SA1",
    source: "bonfire_poll_question"

  import Ecto.Changeset

  pointable_schema do
    # field :name, :string
    # field :description, :string
    field :proposal_dates, {:array, :utc_datetime_usec}
    field :voting_dates, {:array, :utc_datetime_usec}
    field :weighting, :integer
  end

  @doc false
  def changeset(question \\ %Bonfire.Poll.Question{}, attrs) do
    question
    # :name, :description, 
    |> cast(attrs, [
      :proposal_dates,
      :voting_dates,
      :weighting
    ])

    # |> validate_required([:name])
  end
end

defmodule Bonfire.Poll.Question.Migration do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration
  alias Bonfire.Poll.Question

  defp make_question_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_pointable_table Bonfire.Poll.Question do
        Ecto.Migration.add(:proposal_dates, {:array, :utc_datetime_usec})
        Ecto.Migration.add(:voting_dates, {:array, :utc_datetime_usec})
        Ecto.Migration.add(:weighting, :integer)
        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_question_table, do: make_question_table([])
  defmacro create_question_table(do: body), do: make_question_table(body)

  def drop_question_table(), do: drop_pointable_table(Bonfire.Poll.Question)

  defp maa(:up), do: make_question_table([])

  defp maa(:down) do
    quote do: Bonfire.Poll.Question.Migration.drop_question_table()
  end

  defmacro migrate_question() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(maa(:up)),
        else: unquote(maa(:down))
    end
  end
end
