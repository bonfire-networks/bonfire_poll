defmodule Bonfire.Poll.Votes do
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  use Arrows
  # import Bonfire.Poll
  import ActivityPub.Config, only: [is_in: 2]
  alias Bonfire.Poll.{Questions, Question, Vote}
  alias Ecto.Changeset
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Vote
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Answer",
      {"Create", "Answer"},
      {"Update", "Answer"}
    ]

  # TODO: configurable
  def scores,
    do: [
      {"∞", "Block", "ph:prohibit-bold",
       "I need to express a veto, because this would harm a person or group, or it goes against our shared values or goals"},
      {-2, "Disagree", "ph:smiley-sad", "I am strongly opposed"},
      {-1, "Concerned", "ph:smiley-meh",
       "I think this may be a mistake, or I have a different opinion"},
      {0, "Neutral", "ph:smiley-blank", "Not relevant to me, I don't have an opinion"},
      {1, "Seems fine", "ph:smiley", "I'm OK to try this for now"},
      {2, "Great", "ph:smiley-wink", "This meets my needs and aligns with my values and goals"}
    ]

  def get(subject, object, opts \\ []),
    do:
      Edges.get(
        __MODULE__,
        subject,
        object,
        opts
        |> Keyword.put_new(:skip_boundary_check, true)
      )

  def get!(subject, object, opts \\ []),
    do:
      Edges.get!(
        __MODULE__,
        subject,
        object,
        opts
        |> Keyword.put_new(:skip_boundary_check, true)
      )

  def by_voter(subject, opts \\ []) when is_map(subject) or is_binary(subject) do
    opts = to_options(opts)

    opts
    |> Keyword.put(:subject, subject)
    |> query(
      opts
      |> Keyword.put_new(:current_user, subject)
      |> Keyword.put_new(:skip_boundary_check, true)
    )
    |> repo().many()
  end

  def for_choice(choice, opts \\ []) when is_map(choice) or is_binary(choice) do
    opts = to_options(opts)

    opts
    |> Keyword.put(:object, choice)
    |> query(
      opts
      |> Keyword.put_new(:skip_boundary_check, true)
    )
    |> repo().many()
  end

  def list(filters \\ [], opts \\ []),
    do:
      query(
        filters,
        to_options(opts)
        |> Keyword.put_new(:skip_boundary_check, true)
      )
      |> repo().many()

  @doc """
  Returns votes count or weighted total for a choice, only if poll voting is closed or owned by current user.

  For weighted_multiple polls, returns the sum of weights for all votes on the choice.
  For other formats, returns the count of votes.
  Returns nil if results are not visible.
  """
  def calculate_if_visible(choice, poll, opts \\ []) do
    if results_visible?(choice, poll, opts) do
      case Map.get(poll, :voting_format, nil) || Bonfire.Poll.Questions.default_voting_format() do
        "weighted_multiple" ->
          # Get all votes for this choice and calculate weights
          for_choice(choice, opts)
          ~> calculate_total(poll)

        _ ->
          # just count votes
          count(choice, opts)
      end
    else
      nil
    end
  end

  @doc """
  Returns the average vote weight (rounded) for a choice, gated on result
  visibility. Returns nil if results are not visible.
  """
  def calculate_average_if_visible(choice, poll, opts \\ []) do
    if results_visible?(choice, poll, opts) do
      weighting = Map.get(poll, :weighting, 1) || 1
      votes = for_choice(choice, opts) |> List.wrap()

      votes
      |> calculate_total(weighting)
      |> calculate_average_base_score(length(votes))
    else
      nil
    end
  end

  @doc "Returns true a choice only if poll voting is closed or owned by current user"
  def results_visible?(choice, poll, opts \\ []) do
    current_user = current_user(opts)
    is_owner = current_user && Bonfire.Boundaries.can?(current_user, :edit, poll)

    is_owner || Questions.voting_ended?(poll)
  end

  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:vote, object, skip_boundary_check: true)

  @doc """
  Total vote count per question, as a single grouped SQL query.
  Returns `%{question_id => count}`. Missing keys mean zero.

  Joins Ranked (choices belonging to a question) → Edge (votes targeting
  those choices) → Vote (filters edges to vote rows via `Vote.id == Edge.id`).
  """
  def counts_for_questions([]), do: %{}

  def counts_for_questions(question_ids) when is_list(question_ids) do
    from(r in Bonfire.Data.Assort.Ranked,
      join: e in Bonfire.Data.Edges.Edge,
      on: e.object_id == r.item_id,
      join: v in Bonfire.Poll.Vote,
      on: v.id == e.id,
      where: r.scope_id in ^question_ids,
      group_by: r.scope_id,
      select: {r.scope_id, count(v.id)}
    )
    |> repo().all()
    |> Map.new()
  end

  def counts_for_questions(_), do: %{}

  @doc "Empty read model for a question's poll preview vote state."
  def empty_preview_vote_state,
    do: %{counts_by_choice_id: %{}, vetoed_choice_ids: MapSet.new(), my_vote_weights: %{}}

  @doc """
  Vote state for a single question preview.

  This keeps the preview component from deriving totals or viewer-specific
  state from preloaded vote edges. Use `preview_vote_state_for_questions/2`
  when rendering many polls.
  """
  def preview_vote_state_for_question(question, current_user \\ nil) do
    question_id = id(question)

    question
    |> List.wrap()
    |> preview_vote_state_for_questions(current_user)
    |> Map.get(question_id, empty_preview_vote_state())
  end

  @doc """
  Vote state for many question previews, keyed by question id.

  Each value contains:

    * `:counts_by_choice_id` - aggregate vote counts, `%{choice_id => count}`
    * `:vetoed_choice_ids` - choices with at least one veto vote
    * `:my_vote_weights` - the current viewer's own votes, `%{choice_id => weight}`

  Missing choices mean zero votes / no viewer vote.
  """
  def preview_vote_state_for_questions(questions, current_user \\ nil) do
    question_ids = question_ids(questions)
    counts_by_question = choice_counts_for_questions(question_ids)
    vetoes_by_question = vetoed_choice_ids_for_questions(question_ids)
    my_votes_by_question = voter_choice_weights_for_questions(current_user, question_ids)

    Map.new(question_ids, fn question_id ->
      {question_id,
       %{
         counts_by_choice_id: Map.get(counts_by_question, question_id, %{}),
         vetoed_choice_ids: Map.get(vetoes_by_question, question_id, MapSet.new()),
         my_vote_weights: Map.get(my_votes_by_question, question_id, %{})
       }}
    end)
  end

  defp choice_counts_for_questions(questions) do
    question_ids = question_ids(questions)

    if question_ids == [] do
      %{}
    else
      questions_votes_query(question_ids)
      |> group_by([ranked: r], [r.scope_id, r.item_id])
      |> select([ranked: r, vote: v], {r.scope_id, r.item_id, count(v.id)})
      |> repo().all()
      |> nested_choice_map()
    end
  end

  defp vetoed_choice_ids_for_questions(questions) do
    question_ids = question_ids(questions)

    if question_ids == [] do
      %{}
    else
      questions_votes_query(question_ids)
      |> where([vote: v], is_nil(v.vote_weight))
      |> distinct(true)
      |> select([ranked: r], {r.scope_id, r.item_id})
      |> repo().all()
      |> Enum.reduce(%{}, fn {question_id, choice_id}, acc ->
        Map.update(acc, question_id, MapSet.new([choice_id]), &MapSet.put(&1, choice_id))
      end)
    end
  end

  defp voter_choice_weights_for_questions(nil, _questions), do: %{}

  defp voter_choice_weights_for_questions(voter, questions) do
    question_ids = question_ids(questions)

    case {id(voter), question_ids} do
      {voter_id, [_ | _]} when is_binary(voter_id) ->
        questions_votes_query(question_ids)
        |> where([edge: e], e.subject_id == ^voter_id)
        |> select([ranked: r, vote: v], {r.scope_id, r.item_id, v.vote_weight})
        |> repo().all()
        |> nested_choice_map()

      _ ->
        %{}
    end
  end

  defp question_ids(questions) do
    questions
    |> List.wrap()
    |> Enum.map(&id/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp nested_choice_map(rows) do
    Enum.reduce(rows, %{}, fn {question_id, choice_id, value}, acc ->
      put_nested_choice(acc, question_id, choice_id, value)
    end)
  end

  defp put_nested_choice(acc, question_id, choice_id, value) do
    Map.update(acc, question_id, %{choice_id => value}, &Map.put(&1, choice_id, value))
  end

  defp questions_votes_query(question_ids) do
    from(r in Bonfire.Data.Assort.Ranked,
      as: :ranked,
      join: e in Bonfire.Data.Edges.Edge,
      as: :edge,
      on: e.object_id == r.item_id,
      join: v in Bonfire.Poll.Vote,
      as: :vote,
      on: v.id == e.id,
      where: r.scope_id in ^question_ids
    )
  end

  def vote(voter, question, choices, opts \\ [])

  #   def vote(%{} = voter, %{} = question, choices, opts) do
  #     if Bonfire.Boundaries.can?(voter, :vote, question) do
  #       vote(voter, question, choices, opts)
  #     else
  #       error(l("Sorry, you cannot vote on this"))
  #     end
  #   end

  def vote(%{} = voter, question, choices, opts) when is_binary(question) do
    with {:ok, question} <-
           Bonfire.Poll.Questions.read(
             question,
             opts ++
               [
                 current_user: voter,
                 #  verbs: [:vote]
                 # FIXME: temp until we run fixtures with vote verb
                 verbs: [:vote]
               ]
           ) do
      # debug(choice)
      vote(voter, question, choices, opts)
    else
      _ ->
        error(question, l("Sorry, you cannot vote on this"))
    end
  end

  def vote(voter, question, choices, opts) do
    if not Bonfire.Poll.Questions.voting_open?(question) do
      {:error, "Voting is not open for this poll"}
    else
      voting_format =
        Map.get(question, :voting_format, nil) || Bonfire.Poll.Questions.default_voting_format()

      if voting_format == "single" and length(choices) > 1 do
        {:error, "Only one choice allowed for single-choice polls"}
      else
        # multiple choice
        with {:ok, votes} when is_list(votes) <-
               choices
               |> load_choices(voter, opts)
               |> Enum.map(&register_vote_choice(voter, question, &1, opts))
               |> all_oks_or_error(),
             {:ok, vote_activity} <- send_vote_activity(voter, question, votes, opts) do
          {:ok, vote_activity}
        end
      end
    end
  end

  defp load_choices(choices_weights, voter, opts) do
    choices_weights =
      List.wrap(choices_weights)
      |> Enum.reduce(%{}, fn
        %{choice_id: cid, weight: w}, acc -> Map.put(acc, cid, w)
        %{choice_id: cid}, acc -> Map.put(acc, cid, 1)
        _, acc -> acc
      end)
      |> Map.new()

    # assumes choices contains choice IDs as key and weight as values
    choices_weights
    #  TODO: if choices are already loaded, use those (and maybe re-check boundaries) instead of reloading them
    |> Map.keys()
    |> Bonfire.Boundaries.load_pointers!(
      opts ++
        [
          current_user: voter,
          #  verbs: [:vote], # TODO
          skip_boundary_check: true
        ]
    )
    |> Objects.preload_creator()
    |> Enum.map(fn %{id: id} = choice ->
      {choice, choices_weights[id] || 1}
    end)
  end

  def register_vote_choice(voter, question, choice, opts \\ [])

  def register_vote_choice(%{} = voter, %{} = question, {choice, weight}, opts) do
    case do_create_vote_choice(voter, choice, weight, opts) do
      {:ok, vote} ->
        {:ok, vote}

      {:error, e} ->
        case get(voter, choice) do
          {:ok, vote} ->
            {:ok, vote}

          _ ->
            error(e)
        end
    end
  end

  defp do_create_vote_choice(voter, choice, weight, opts) do
    # don't create an activity or set ACLs on each individual vote on a choice, since we do that in `send_vote_activity/4` instead
    Edges.changeset_base_with_creator(Vote, voter, choice, opts)
    |> Vote.changeset(%{vote_weight: weight || 1})
    |> Edges.insert(voter, choice)
  end

  def send_vote_activity(%{} = voter, %{} = question, registered_votes, opts) do
    question =
      Objects.preload_creator(question)

    object_creator =
      opts[:object_creator] ||
        Objects.object_creator(question)

    choice_creators =
      registered_votes
      |> List.wrap()
      |> Enum.map(&Objects.object_creator(e(&1, :edge, :object, nil)))

    opts =
      [
        # TODO: make configurable
        boundary: "mentions",
        to_circles: [Enums.id(object_creator), Enums.ids(choice_creators)],
        to_feeds:
          Feeds.maybe_creator_notification(
            voter,
            [object_creator, choice_creators],
            opts
          )
      ] ++ List.wrap(opts)

    case do_create_vote_activity(voter, question, opts) do
      {:ok, vote_activity} ->
        vote_activity =
          vote_activity
          |> Map.put(:votes, registered_votes)

        # TODO: federate?
        # Social.maybe_federate_and_gift_wrap_activity(voter, vote_activity)

        {:ok, vote_activity}

      {:error, e} ->
        case get(voter, question) do
          {:ok, vote_activity} ->
            {:ok,
             vote_activity
             |> Map.put(:votes, registered_votes)}

          _ ->
            error(e)
        end
    end
  end

  defp do_create_vote_activity(voter, question, opts) do
    Edges.changeset(Vote, voter, :vote, question, opts)
    |> Edges.insert(voter, question)
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Vote, filters, opts)
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  #   def get_total(proposal, votes, %{} = question) do
  #     proposal_id = id(proposal)
  #
  #     votes
  #     |> Enum.filter(fn vote -> vote.proposal_id == proposal_id end)
  #     |> get_total(question)
  #   end

  @doc """
  Sums the weights of all votes for a choice.

  ## Examples

      iex> Bonfire.Poll.Votes.calculate_total([%{vote_weight: 2}, %{vote_weight: 1}], 1)
      3

      iex> Bonfire.Poll.Votes.calculate_total([%{vote_weight: -1}, %{vote_weight: 2}], 2)
      0
  """
  def calculate_total(votes, weighting, sum \\ 0)

  def calculate_total(nil, _weighting, nil), do: nil
  def calculate_total(_vote_weight, _weighting, nil), do: nil

  def calculate_total(votes, %{weighting: weighting} = _question, sum),
    do: calculate_total(votes, weighting, sum)

  def calculate_total(votes, weighting, sum) when is_list(votes) do
    votes
    |> Enum.reduce(sum, fn vote, sum ->
      calculate_total(vote, weighting, sum)
    end)
  end

  def calculate_total(%{vote_weight: vote_weight} = _vote, weighting, sum),
    do: calculate_total(vote_weight, weighting, sum)

  def calculate_total(%{vote: %{vote_weight: vote_weight} = vote}, weighting, sum),
    do: calculate_total(vote_weight, weighting, sum)

  def calculate_total(vote_weight, weighting, sum) do
    case vote_weight do
      nil -> nil
      vote when vote < 0 -> vote * weighting + sum
      vote -> vote + sum
    end
  end

  @doc """
  Returns the average base score (rounded) for a choice.

  ## Examples

      iex> Bonfire.Poll.Votes.calculate_average_base_score(3, 2)
      2

      iex> Bonfire.Poll.Votes.calculate_average_base_score(nil, 2)
      nil

      iex> Bonfire.Poll.Votes.calculate_average_base_score(0, 0)
      0
  """
  def calculate_average_base_score(nil, _num_voters), do: nil
  def calculate_average_base_score(_, nil), do: nil
  def calculate_average_base_score([], _), do: nil

  def calculate_average_base_score(total, num_voters)
      when is_integer(total) and is_integer(num_voters) do
    if num_voters > 0 do
      i = total / num_voters
      #   round(i * 100) / 100
      round(i)
    else
      0
    end
  end

  def calculate_average_base_score(votes, %Question{} = question)
      when is_list(votes) and votes != [] do
    calculate_total(votes, question)
    |> calculate_average_base_score(length(votes))
  end

  def get_average_emoji(total, num_voters, %{} = question, scores \\ scores()) do
    case calculate_average_base_score(total, num_voters) do
      nil -> find_score("∞", scores)
      value -> find_score(round(value), scores)
    end
  end

  defp find_score(value, scores \\ scores()) do
    Enum.find(scores, fn
      {^value, _, _, _} -> true
      _ -> false
    end)
  end

  # For incoming votes (Create activities with Note objects)
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Create"}} = activity,
        %{
          data: %{
            "type" => type,
            "name" => option_name,
            "inReplyTo" => question_uri
          }
        } = ap_object
      )
      when is_binary(option_name) and is_in(type, ["Answer", "Note"]) do
    # Find local question by URI
    with {:ok, question} <-
           Questions.get_by_uri(question_uri, current_user: creator, verbs: [:vote]),
         {:ok, choice} <- Choices.find_choice_by_name(question, option_name) do
      # Record vote
      vote(creator, question, choice, [])
    else
      e ->
        warn(
          e,
          "Could not process incoming reply as a vote, falling back to normal reply handling"
        )

        maybe_apply(Bonfire.Posts, :ap_receive_activity, [creator, activity, ap_object])
    end
  end

  def ap_receive_activity(
        creator,
        activity,
        %{"id" => _} = ap_object
      ) do
    ap_receive_activity(creator, activity, %{data: ap_object})
  end
end
