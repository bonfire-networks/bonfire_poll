defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.ChoiceLive

  prop object, :any
  prop activity_component_id, :any, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop vote_state, :any, default: nil
  prop thread_title, :any, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  def preloads(),
    do: [
      :post_content,
      # :peered, # not sure if needed?
      choices: [
        :post_content,
        # Vote state is loaded through `Votes.preview_vote_state_for_*`, not
        # `object_voted`, so totals and viewer state stay explicitly scoped.
        created: [creator: [:profile, :character]]
      ]
    ]

  def post_content(object) do
    e(object, :post_content, nil) || object
  end

  @doc "Pre-compute every value the template branches read, so the .sface stays flat."
  def view_state(question, is_remote \\ false, current_user \\ nil, vote_state \\ nil) do
    choices = e(question, :choices, []) || []
    remote_stats = if is_remote, do: remote_poll_stats(question), else: empty_remote_stats()
    end_time = end_time(question, remote_stats)
    voting_format = e(question, :voting_format, nil) || Questions.default_voting_format()

    vote_state = preview_vote_state(question, is_remote, current_user, vote_state)
    local_counts = e(vote_state, :counts_by_choice_id, %{})
    local_histograms = e(vote_state, :score_histogram_by_choice_id, %{})

    vetoed_ids =
      if voting_format == "weighted_multiple",
        do: choice_ids(e(vote_state, :vetoed_choice_ids, [])),
        else: []

    my_votes =
      vote_state
      |> e(:my_vote_weights, %{})
      |> Map.new(fn {choice_id, weight} -> {choice_id, weight_to_score(weight)} end)

    counts_by_choice_id =
      Map.new(choices, fn c ->
        {id(c), choice_vote_count(c, remote_stats, Map.get(local_counts, id(c), 0))}
      end)

    total_votes = max(Enum.sum(Map.values(counts_by_choice_id)), remote_stats.total_votes)
    voter_count = max(e(vote_state, :voter_count, 0), e(remote_stats, :voters_count, 0))
    weighting = e(question, :weighting, 1) || 1

    closed = closed?(end_time)
    voted? = my_votes != %{}
    policy = Questions.results_visibility_policy()

    # Whether the viewer is *allowed* to see the tally (owner, or per policy).
    may_see_results =
      Questions.results_visible?(question,
        current_user: current_user,
        viewer_voted?: voted?,
        ended?: closed,
        policy: policy
      )

    results_visible = may_see_results and (closed or voted?)

    # Hidden-until-close (per-poll `hide_results`) disables the pre-vote peek.
    hidden_until_close = results_locked?(question, end_time)

    # A not-yet-voted viewer on an open poll may peek at results early, unless
    # the policy defers them to close (`:after_close`) or the poll hides them.
    results_toggleable =
      not closed and not voted? and not results_visible and
        policy in [:after_vote, :always] and not hidden_until_close

    %{
      choices: choices,
      has_voted: voted?,
      counts_by_choice_id: counts_by_choice_id,
      my_votes: my_votes,
      vetoed_ids: vetoed_ids,
      score_histogram_by_choice_id: local_histograms,
      end_time: end_time,
      closed: closed,
      locked: not closed and not voted? and not results_visible and not results_toggleable,
      results_visible: results_visible,
      results_toggleable: results_toggleable,
      winning_ids:
        winning_ids(voting_format, choices, counts_by_choice_id, local_histograms, weighting),
      voting_format: voting_format,
      total_votes: total_votes,
      voter_count: voter_count,
      proposal_open: Questions.proposal_open?(question),
      time_remaining_label: time_remaining(end_time),
      proposal_end_label: time_remaining(List.last(e(question, :proposal_dates, []))),
      question_without_choices: Map.drop(question, [:choices])
    }
  end

  defp preview_vote_state(_question, true, _current_user, _vote_state),
    do: Votes.empty_preview_vote_state()

  defp preview_vote_state(question, _is_remote, _current_user, vote_state)
       when is_map(vote_state) do
    if Map.has_key?(vote_state, :counts_by_choice_id) do
      vote_state
    else
      Map.get(vote_state, id(question), Votes.empty_preview_vote_state())
    end
  end

  defp preview_vote_state(question, _is_remote, current_user, _vote_state),
    do: Votes.preview_vote_state_for_question(question, current_user)

  defp choice_ids(%MapSet{} = ids), do: MapSet.to_list(ids)
  defp choice_ids(ids) when is_list(ids), do: ids
  defp choice_ids(_), do: []

  defp empty_remote_stats,
    do: %{voters_count: 0, total_votes: 0, choice_counts: %{}, end_time: nil}

  @doc "Vote count for a choice: the higher of local aggregate and remote stats."
  def choice_vote_count(choice, remote_stats \\ %{}, local_count \\ 0)

  def choice_vote_count(choice, %{choice_counts: choice_counts}, local_count)
      when is_map(choice_counts) do
    name = e(choice, :post_content, :name, nil)
    max(local_count || 0, Map.get(choice_counts, name, 0))
  end

  def choice_vote_count(_choice, _remote_stats, local_count),
    do: local_count || 0

  @doc "Get remote poll stats from cached AP object"
  def remote_poll_stats(question) do
    with question_id when is_binary(question_id) <- id(question),
         {:ok, %{data: data}} when is_map(data) <-
           ActivityPub.Object.get_cached(pointer: question_id) do
      options =
        case Questions.options_key_from_ap_data(data) do
          nil -> []
          key -> data[key] || []
        end

      choice_counts = Map.new(options, &ap_option_count/1)
      total = Enum.sum(Map.values(choice_counts))

      %{
        voters_count: data["votersCount"] || total,
        total_votes: total,
        choice_counts: choice_counts,
        end_time: data["endTime"]
      }
    else
      _ -> empty_remote_stats()
    end
  end

  defp ap_option_count(opt) do
    count =
      case get_in(opt, ["replies", "totalItems"]) do
        n when is_integer(n) -> n
        _ -> 0
      end

    {opt["name"], count}
  end

  @doc """
  Maps a stored `vote_weight` to the score shown in the UI: `"∞"` for a veto
  (the schema stores it as `nil`), otherwise the integer weight as-is.
  """
  def weight_to_score(nil), do: "∞"
  def weight_to_score(weight) when is_integer(weight), do: weight

  @doc "True when the poll's deadline has passed."
  def closed?(end_time) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> closed?(dt)
      _ -> false
    end
  end

  def closed?(%DateTime{} = end_time),
    do: DateTime.compare(end_time, DateTime.utc_now()) == :lt

  def closed?(_), do: false

  @doc """
  True when results should be hidden until close and the poll is still open.
  The Question schema doesn't persist `hide_results` yet (it lives in the
  composer's tuning state), so this is `false` until that field is added.
  """
  def results_locked?(question, end_time) do
    e(question, :hide_results, false) and not closed?(end_time)
  end

  @doc "Resolve the deadline from a question. Falls back to remote stats `end_time`."
  def end_time(question, remote_stats \\ %{})

  def end_time(_question, %{end_time: end_time}) when not is_nil(end_time), do: end_time

  def end_time(question, _) do
    case e(question, :voting_dates, nil) do
      [_start, %DateTime{} = end_dt] -> end_dt
      [_start, end_str] when is_binary(end_str) -> end_str
      _ -> nil
    end
  end

  @doc """
  The winning choice id(s) for a format.
  """
  def winning_ids("weighted_multiple", choices, _counts_by_choice_id, histograms, weighting) do
    winning_choice_ids(choices, fn choice ->
      histograms
      |> Map.get(id(choice), %{})
      |> consent_net(weighting)
    end)
  end

  def winning_ids(_format, choices, counts_by_choice_id, _histograms, _weighting) do
    winning_choice_ids(choices, &Map.get(counts_by_choice_id, id(&1), 0))
  end

  # Net agreement for one option: positive reaction scores as-is, negatives
  # scaled by `weighting`; the Block (nil) bucket is excluded (a veto resolves
  # via `decision_state`, not by lowering this score). Floored at 0 so an option
  # only ranks as a winner when agreement genuinely outweighs disagreement.
  defp consent_net(histogram, weighting) do
    histogram
    |> Enum.reduce(0, fn
      {nil, _count}, acc -> acc
      {weight, count}, acc when weight < 0 -> acc + weight * weighting * count
      {weight, count}, acc -> acc + weight * count
    end)
    |> max(0)
  end

  @doc "Ids of choice(s) tied at the highest vote count; `[]` when no votes."
  def winning_choice_ids(choices, count_fn \\ &choice_vote_count/1)

  def winning_choice_ids(choices, count_fn) when is_list(choices) do
    counts = Enum.map(choices, fn c -> {id(c), count_fn.(c)} end)

    case Enum.max_by(counts, fn {_, n} -> n end, fn -> {nil, 0} end) do
      {_, 0} -> []
      {_, top} -> for {choice_id, ^top} <- counts, do: choice_id
    end
  end

  def winning_choice_ids(_, _), do: []

  @doc "Calculate time remaining for a poll"
  def time_remaining(nil), do: nil

  def time_remaining(end_time) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> time_remaining(dt)
      _ -> nil
    end
  end

  def time_remaining(%DateTime{} = end_time) do
    now = DateTime.utc_now()

    case DateTime.compare(end_time, now) do
      :lt ->
        l("Closed")

      :eq ->
        l("Closing now")

      :gt ->
        diff = DateTime.diff(end_time, now, :second)

        cond do
          diff < 3600 ->
            n = div(diff, 60)
            lp("1 minute left", "%{count} minutes left", n, count: n)

          diff < 86400 ->
            n = div(diff, 3600)
            lp("1 hour left", "%{count} hours left", n, count: n)

          true ->
            n = div(diff, 86400)
            lp("1 day left", "%{count} days left", n, count: n)
        end
    end
  end

  def time_remaining(_), do: nil

  @doc "Localised, singular-aware vote count: `1 vote` / `N votes`."
  def pluralize_votes(n), do: lp("1 vote", "%{count} votes", n, count: n)

  @doc """
  Localised count label for the status band, in each format's own noun. Consent
  options collect *reactions* (agree / concern / block), not votes "for" — so
  the band reads `2 reactions`, while tally polls read `2 votes`.
  """
  def count_label("weighted_multiple", n), do: ChoiceLive.reactions_label(n)
  def count_label(_format, n), do: pluralize_votes(n)

  @doc """
  The kind of decision a poll represents, as a label. Consent decisions read
  differently from tally polls because they resolve differently, so the band
  names the process rather than calling everything a "poll". (The band's icon is
  the decision *state*, not the kind,  see `state_color_class/1`.)
  """
  def process_kind("weighted_multiple"), do: l("Consent decision")
  def process_kind("multiple"), do: l("Multiple choice")
  def process_kind(_), do: l("Poll")

  @doc """
  Resolves the headline state of a poll from already-computed view state, so
  open-vs-closed (and *how* a consent decision closed) is unmistakable.

  Consent (`weighted_multiple`) maps a standing veto to `:no_consensus`, and a
  close where no option reached net agreement (none won, yet nothing was
  blocked) to `:no_agreement` — kept distinct from `:decided` so the UI never
  claims agreement that didn't happen. Tally polls just close. Returns one of
  `:open | :decided | :no_agreement | :no_consensus | :closed_empty | :closed`.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("weighted_multiple", false, 3, [], ["a"])
      :open
      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("weighted_multiple", true, 3, ["b"], [])
      :no_consensus
      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("weighted_multiple", true, 3, [], ["a"])
      :decided
      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("weighted_multiple", true, 3, [], [])
      :no_agreement
      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("single", true, 5, [], ["a"])
      :closed
      iex> Bonfire.Poll.Web.Preview.QuestionLive.decision_state("single", true, 0, [], [])
      :closed_empty
  """
  def decision_state(_format, false = _closed, _total, _vetoed, _winning), do: :open

  def decision_state("weighted_multiple", true, _total, vetoed, _winning) when vetoed != [],
    do: :no_consensus

  def decision_state(_format, true, 0, _vetoed, _winning), do: :closed_empty
  def decision_state("weighted_multiple", true, _total, _vetoed, [] = _winning), do: :no_agreement
  def decision_state("weighted_multiple", true, _total, _vetoed, _winning), do: :decided
  def decision_state(_format, true, _total, _vetoed, _winning), do: :closed

  @doc """
  Plain-language label for a `decision_state/5` value, in the poll's own
  vocabulary (an open consent decision is "gathering reactions", an open tally
  poll is just "open"). Shown both as the status-icon tooltip and as readable
  text next to the vote count.
  """
  def state_label(:open, "weighted_multiple"), do: l("Gathering reactions")
  def state_label(:open, _format), do: l("Open")
  def state_label(:decided, _format), do: l("Decided")
  def state_label(:no_consensus, _format), do: l("No consensus")
  def state_label(:no_agreement, _format), do: l("No agreement")
  def state_label(_state, _format), do: l("Closed")

  @doc "DaisyUI tone for a `decision_state/5` value, matching the status icon."
  def state_color_class(:open), do: "text-primary"
  def state_color_class(:decided), do: "text-success"
  def state_color_class(:no_consensus), do: "text-error"
  def state_color_class(_state), do: "text-base-content/70"

  @doc "Names of the choices whose ids are in `ids` (for carried / blocked summaries)."
  def choice_names(choices, ids) when is_list(choices) do
    set = MapSet.new(ids || [])

    for choice <- choices,
        MapSet.member?(set, id(choice)),
        name = e(choice, :post_content, :name, nil),
        is_binary(name),
        do: name
  end

  def choice_names(_, _), do: []

  @doc """
  Share (rounded %) held by the winning option(s) for the outcome caption,
  honest to the poll's format so it matches the per-option tally bar.

  Winners tie at the top count, so any winner's count over the denominator is
  the headline number. For `"multiple"` the denominator is the distinct voter
  count (as on the bars), so the caption % equals the bar %; otherwise it is the
  total vote count. Returns `0` when there are no votes or no winner.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.QuestionLive.winning_percent("single", %{"a" => 11, "b" => 9}, ["a"], 20, 20)
      55

      iex> Bonfire.Poll.Web.Preview.QuestionLive.winning_percent("multiple", %{"a" => 8, "b" => 6}, ["a"], 14, 10)
      80

      iex> Bonfire.Poll.Web.Preview.QuestionLive.winning_percent("single", %{"a" => 1}, ["a"], 1, 1)
      100

      iex> Bonfire.Poll.Web.Preview.QuestionLive.winning_percent("single", %{}, [], 0, 0)
      0
  """
  def winning_percent(voting_format, counts_by_choice_id, [first | _], total_votes, voter_count)
      when is_map(counts_by_choice_id) do
    ChoiceLive.tally_percent(
      voting_format,
      Map.get(counts_by_choice_id, first, 0),
      total_votes,
      voter_count
    )
  end

  def winning_percent(_voting_format, _counts, _winning_ids, _total_votes, _voter_count), do: 0
end
