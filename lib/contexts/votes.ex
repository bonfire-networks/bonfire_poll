defmodule Bonfire.Poll.Votes do
  use Bonfire.Common.Utils
  use Arrows
  import Bonfire.Poll
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
      {"∞", "Block", "fontisto:ban",
       "I need to express a veto, because this would harm a person or group, or it goes against our shared values or goals"},
      #   {-3, "Strongly Disagree", "fontisto:rage", "I'm sure this would be a big mistake"},
      {-2, "Disagree", "fontisto:frowning", "I am strongly opposed"},
      {-1, "Concerned", "fontisto:confused",
       "I think this may be a mistake, or I have a different opinion"},
      {0, "Neutral", "fontisto:neutral", "Not relevant to me, I don't have an opinion"},
      {1, "Seems fine", "fontisto:slightly-smile", "I'm OK to try this for now"},
      {2, "Great", "fontisto:heart-eyes",
       "This meets my needs and aligns with my values and goals"}
      # {1, "Seems fine", "fontisto:slightly-smile", ""},
      # {2, "Sounds good", "fontisto:smiley", ""},
      # {3, "Awesome", "fontisto:heart-eyes", ""}
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
          for_choice([object: choice], opts)
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
  Returns votes count for a choice, only if poll voting is closed or owned by current user.

  You'd usually want to use `calculate_if_visible/3` instead.

  Returns nil if results are not visible.
  """
  defp count_if_visible(choice, poll, opts \\ []) do
    if results_visible?(choice, poll, opts) do
      count(choice, opts)
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
               |> debug("loaded_choices being voted on")
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
      |> debug("input_choices_weights")
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
    |> debug()
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
            debug(vote, "the user already voted on this")
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
    |> debug("csss")
    |> Edges.insert(voter, choice)
  end

  def send_vote_activity(%{} = voter, %{} = question, registered_votes, opts) do
    question =
      Objects.preload_creator(question)
      |> debug("the object")

    object_creator =
      (opts[:object_creator] ||
         Objects.object_creator(question))
      |> debug("the creator")

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
             |> debug("the user already voted on this")
             |> Map.put(:votes, registered_votes)}

          _ ->
            error(e)
        end
    end
  end

  defp do_create_vote_activity(voter, question, opts) do
    Edges.changeset(Vote, voter, :vote, question, opts)
    |> debug("csss")
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
      3
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
      {value, _, _, _} -> true
      _ -> false
    end)
  end

  # For incoming votes (Create activities with Note objects)
  def ap_receive_activity(creator, %{data: %{"type" => "Create"}} = activity, %{
        "type" => "Note",
        "name" => option_name,
        "inReplyTo" => question_uri
      }) do
    # Find local question by URI
    with {:ok, question} <-
           Questions.get_by_uri(question_uri, current_user: creator, verbs: [:vote]),
         {:ok, choice} <- Choices.find_choice_by_name(question, option_name) do
      # Record vote
      vote(creator, question, choice, [])
    end
  end
end
