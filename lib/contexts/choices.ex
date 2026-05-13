defmodule Bonfire.Poll.Choices do
  use Bonfire.Common.Utils
  import Bonfire.Poll
  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Questions
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

  def simple_create_and_put(index \\ nil, choices_or_choice_attrs, question_id, opts) do
    initial_index = index || 0

    choices_or_choice_attrs
    |> normalise_choices_input()
    |> Enum.with_index()
    |> Enum.map(fn {choice, i} ->
      do_simple_create_and_put(i + initial_index, choice, question_id, opts)
    end)
    |> all_oks_or_error()
  end

  # List, indexed map (string / atom / mixed keys from `input_to_atoms`), or
  # single attrs map — all normalised to a list with empties dropped.
  defp normalise_choices_input(choices) when is_list(choices) do
    Enum.reject(choices, &choice_empty?/1)
  end

  defp normalise_choices_input(%{} = choices) when map_size(choices) > 0 do
    if indexed_map?(choices) do
      choices
      |> Enum.sort_by(fn {k, _v} -> Types.maybe_to_integer(k, 0) end)
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.reject(&choice_empty?/1)
    else
      if choice_empty?(choices), do: [], else: [choices]
    end
  end

  defp normalise_choices_input(_), do: []

  defp indexed_map?(map) when is_map(map) and map_size(map) > 0 do
    Enum.all?(map, fn {k, _v} ->
      case Types.maybe_to_integer(k, :__not_int__) do
        :__not_int__ -> false
        n -> is_integer(n) and n >= 0
      end
    end)
  end

  defp indexed_map?(_), do: false

  defp choice_empty?(%{} = choice) do
    name = e(choice, :name, nil) || e(choice, "name", nil)
    is_nil(name) or String.trim(to_string(name)) == ""
  end

  defp choice_empty?(_), do: true

  @doc """
  Submit a new proposal (Choice) to an existing Question during its
  proposal phase. Gates on proposal window being open, the boundary check,
  and a non-empty name. The proposer is attached via the
  `Bonfire.Data.Social.Created` mixin so attribution renders on the preview.
  """
  def add_proposal(question, attrs, opts \\ []) do
    with %{} = current_user <- current_user(opts) || {:error, :unauthorized},
         {:ok, %Question{} = question} <- load_question(question, opts),
         :ok <- ensure_proposal_open(question),
         :ok <- ensure_can_contribute(current_user, question),
         :ok <- ensure_name_present(attrs) do
      do_add_proposal(question, attrs, current_user, opts)
    end
  end

  defp load_question(%Question{} = q, _opts), do: {:ok, q}

  defp load_question(question_id, opts) when is_binary(question_id) do
    case Questions.read(question_id, opts) do
      {:ok, %Question{} = q} -> {:ok, q}
      _ -> {:error, :not_found}
    end
  end

  defp load_question(_, _), do: {:error, :not_found}

  defp ensure_proposal_open(%Question{} = q) do
    if Questions.proposal_open?(q), do: :ok, else: {:error, :proposal_phase_closed}
  end

  # Anyone who can `:see` the poll can propose; to restrict, narrow the
  # boundary at creation. Matches how reply-able social posts work.
  defp ensure_can_contribute(current_user, %Question{} = question) do
    if Bonfire.Boundaries.can?(current_user, :see, question),
      do: :ok,
      else: {:error, :not_authorized}
  end

  defp ensure_name_present(attrs) do
    name = e(attrs, :name, nil) || e(attrs, "name", nil)
    if is_binary(name) and String.trim(name) != "", do: :ok, else: {:error, :name_required}
  end

  defp do_add_proposal(%Question{} = question, attrs, current_user, opts) do
    with cs <-
           Bonfire.Social.PostContents.cast(
             %Choice{},
             attrs,
             current_user,
             opts[:boundary] || "public",
             opts
           )
           |> Bonfire.Social.Objects.cast_creator(current_user),
         {:ok, %{id: choice_id} = choice} <- repo().insert(cs),
         {:ok, _} <- put_choice(choice_id, question.id, :last) do
      {:ok, choice}
    end
  end

  defp do_simple_create_and_put(index, attrs, question_id, opts) do
    with cs <-
           Bonfire.Social.PostContents.cast(
             %Choice{},
             attrs,
             current_user(opts),
             opts[:boundary] || "public",
             opts
           ),
         {:ok, %{id: choice_id} = choice} <- repo().insert(cs),
         {:ok, _} <- put_choice(choice_id, question_id, index) do
      {:ok, choice}
    end
  end

  def put_choice(choice, question, position \\ nil) do
    with %Ecto.Changeset{valid?: true} = cs <-
           Bonfire.Data.Assort.Ranked.changeset(%{
             item_id: uid(choice),
             scope_id: uid(question),
             rank_set: position
           })
           |> Ecto.Changeset.unique_constraint([:item_id, :scope_id],
             name: :bonfire_data_ranked_unique_per_scope
           )
           # |> Ecto.Changeset.apply_action(:insert)
           |> debug("Ranked cs"),
         {:ok, ins} <- repo().insert(cs) do
      # TODO: federate
      {:ok, ins}
    else
      # poor man's upsert - TODO fix drag and drop ordering and make better and generic
      {:error, %Ecto.Changeset{} = cs} ->
        warn(cs, "Ranked cs error")
        repo().upsert(cs, [:rank])

      # TODO: federate

      %Ecto.Changeset{} = cs ->
        warn(cs, "Ranked cs error2")

        repo().upsert(cs, [:rank])

      # TODO: federate

      e ->
        error(e)
    end
    |> debug()
  end

  @doc """
  Removes the association between a choice and a question.
  Deletes the Ranked record linking the choice to the question.
  Returns :ok if deleted, {:error, reason} otherwise.
  """
  def remove_choice(choice_id, question_id) do
    repo = repo()

    assoc =
      repo.get_by(Bonfire.Data.Assort.Ranked, item_id: uid(choice_id), scope_id: uid(question_id))

    case assoc do
      nil ->
        {:error, :not_found}

      _ ->
        case repo.delete(assoc, allow_stale: true) do
          # TODO: federate
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def find_choice_by_name(question, name) do
    question = repo().maybe_preload(question, :choices)

    case Enum.find(question.choices, fn c ->
           e(c, :post_content, :name, nil) || e(c, :post_content, :summary, nil) ||
             e(c, :post_content, :html_body, nil) == name
         end) do
      nil -> {:error, :not_found}
      choice -> {:ok, choice}
    end
  end
end
