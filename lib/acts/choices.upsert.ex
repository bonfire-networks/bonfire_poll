defmodule Bonfire.Poll.Acts.Choices.Upsert do
  @moduledoc """
  WIP: Creates a changeset for publishing choice(s) for a question

  Epic Options:
    * `:current_user` - user that will create the choice, required.
    * `:choice_attrs` (configurable) - attrs to create the choice from, required.
    * `:choice_id` (configurable) - id to use for the created choice (handy for creating
      activitypub objects with an id representing their reported creation time)

  Act Options:
    * `:id` - epic options key to find an id to force override with at, default: `:choice_id`
    * `:as` - key to assign changeset to, default: `:choice`.
    * `:attrs` - epic options key to find the attributes at, default: `:choice_attrs`.
  """

  alias Bonfire.Ecto.Acts.Work
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic
  alias Bonfire.Poll.Choices

  alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  # import Untangle

  # see module documentation
  @doc false
  def run(epic, act) do
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(
          epic,
          act,
          current_user,
          "Skipping due to missing current_user"
        )

        epic

      true ->
        as = Keyword.get(act.options, :as) || Keyword.get(act.options, :on, :choice)
        attrs_key = Keyword.get(act.options, :attrs, :choice_attrs)

        id_key = Keyword.get(act.options, :id, :choice_id)
        id = epic.assigns[:options][id_key]

        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        _boundary = epic.assigns[:options][:boundary]

        maybe_debug(
          epic,
          act,
          attrs_key,
          "Assigning changeset to :#{as} using attrs"
        )

        # maybe_debug(epic, act, attrs, "Post attrs")
        if attrs == %{}, do: maybe_debug(act, attrs, "empty attrs")

        choice =
          with _ when is_binary(id) <- true,
               {:ok, choice} <- Bonfire.Social.Objects.get(id) do
            choice
          else
            _ ->
              %Needle.Pointer{}
          end

        Ecto.Changeset.change(choice, attrs)
        |> Map.put(:action, :upsert)
        |> maybe_overwrite_id(id)
        |> Epic.assign(epic, as, ...)
        |> Work.add(:choice)
    end
  end

  defp maybe_overwrite_id(changeset, nil) do
    changeset
    |> Map.put(:action, :insert)
  end

  defp maybe_overwrite_id(changeset, id),
    do: Changeset.put_change(changeset, :id, id)
end
