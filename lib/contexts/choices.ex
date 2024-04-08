defmodule Bonfire.Poll.Choices do
  use Bonfire.Common.Utils
  import Bonfire.Poll.Integration
  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Choice
  alias Bonfire.Epics.Epic

  # TODO?
  # def upsert(options \\ []) do
  #   with {:ok, %{id: id} = published} <-
  #          Bonfire.Pages.run_epic(
  #            :upsert,
  #            options ++ [do_not_strip_html: true],
  #            __MODULE__,
  #            :choice
  #          ) do
  #     if options[:question_id],
  #       do:
  #         put_choice(id, options[:question_id])
  #         |> debug("put_in_page - TODO: move to epic?")

  #     {:ok, published}
  #   end
  # end

  def simple_create_and_put(index \\ nil, choices_or_choice_attrs, question_id, opts)

  def simple_create_and_put(index, %{name: _} = attrs, question_id, opts) do
    with cs <-
           Bonfire.Social.PostContents.cast(
             %Choice{},
             attrs,
             current_user(opts),
             opts[:boundary] || "public",
             opts
           ),
         {:ok, %{id: choice_id} = _published} <- repo().insert(cs) do
      put_choice(choice_id, question_id, index)

      {:ok, choice_id}
    end
  end

  def simple_create_and_put(nil, choices, question_id, opts) when is_list(choices) do
    choices
    |> Enum.with_index()
    |> Enum.map(fn {choice, i} -> simple_create_and_put(i, choice, question_id, opts) end)
  end

  def simple_create_and_put(nil, %{} = choices, question_id, opts) do
    choices
    |> Enum.with_index()
    |> Enum.map(fn {{i, choice}, fallback_i} ->
      simple_create_and_put(Types.maybe_to_integer(i) || fallback_i, choice, question_id, opts)
    end)
  end

  def put_choice(choice, question, position \\ nil) do
    with {:ok, %Ecto.Changeset{valid?: true} = cs} <-
           Bonfire.Data.Assort.Ranked.changeset(%{
             item_id: ulid(choice),
             scope_id: ulid(question),
             rank_set: position
           })
           |> Ecto.Changeset.unique_constraint([:item_id, :scope_id],
             name: :bonfire_data_ranked_unique_per_scope
           )
           # |> Ecto.Changeset.apply_action(:insert)
           |> debug(),
         {:ok, ins} <- repo().insert(cs) do
      {:ok, ins}
    else
      # poor man's upsert - TODO fix drag and drop ordering and make better and generic
      {:error, %Ecto.Changeset{} = cs} ->
        repo().upsert(cs, [:rank])

      %Ecto.Changeset{} = cs ->
        repo().upsert(cs, [:rank])

      e ->
        error(e)
    end
    |> debug()
  end
end
