defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.Common.Cache
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

  # no tallies and no "See results" (eg. in the dashboard widget); pass an empty `vote_state` too so nothing is queried
  prop hide_results, :boolean, default: false
  prop thread_title, :any, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false
  prop permalink, :string, default: nil

  # what `update_many/1` and the "See results" events keep for the poll shown: the viewer's own votes and, once loaded, the tallies
  data qstate, :any, default: nil
  data qstate_for, :any, default: nil

  defp vote_page_path(permalink, question) do
    usable_path(permalink) || maybe_path(question) || "/login"
  end

  defp usable_path(path) when is_binary(path) do
    path = String.trim(path)

    if path != "" and path != "#" and String.starts_with?(path, ["/", "http://", "https://"]) do
      String.trim_trailing(path, "#")
    end
  end

  defp usable_path(_), do: nil

  defp maybe_path(nil), do: nil
  defp maybe_path(object), do: path(object)

  # true when rendering inside an embed iframe, where guests can't use the in-app
  # login flow so the CTA opens the poll's page on the instance in a new tab instead
  defp embed_cta?(:thread_embed, _context), do: true
  # in embeds (`InstancePinsLive` sets `link_target` "_blank") pins render as `:widget`
  defp embed_cta?(:widget, context),
    do: e(context, :link_target, nil) == "_blank"

  defp embed_cta?(_, _), do: false

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
  def view_state(
        question,
        is_remote \\ false,
        current_user \\ nil,
        vote_state \\ nil,
        hide_results \\ false
      ) do
    choices = e(question, :choices, []) || []
    voting_format = e(question, :voting_format, nil) || Questions.default_voting_format()

    vote_state = preview_vote_state(question, is_remote, current_user, vote_state)
    tallies_loaded = Map.get(vote_state, :tallies_loaded, true)

    # a remote poll's counts come from its cached ActivityPub object, read only once the tallies are loaded
    remote_stats =
      if is_remote and tallies_loaded, do: remote_poll_stats(question), else: empty_remote_stats()

    end_time = end_time(question, remote_stats)
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
    # (`update_many/1` works it out for closed polls and passes it in the state, so the edit-permission check inside runs once per render)
    may_see_results =
      case vote_state do
        %{may_see_results: known} ->
          known

        _ ->
          Questions.results_visible?(question,
            current_user: current_user,
            viewer_voted?: voted?,
            ended?: closed,
            policy: policy
          )
      end

    # Whether the viewer may see the results now (not whether they are loaded yet).
    results_allowed = not hide_results and may_see_results and (closed or voted?)

    # Hidden-until-close (per-poll `hide_results`) disables the pre-vote peek.
    hidden_until_close = results_locked?(question, end_time)

    # A not-yet-voted viewer on an open poll may peek at results early, unless
    # the policy defers them to close (`:after_close`) or the poll hides them.
    results_toggleable =
      not hide_results and not closed and not voted? and not results_allowed and
        policy in [:after_vote, :always] and not hidden_until_close

    # Counts show only once the tallies are loaded ("See results", a vote just cast, or a cached closed poll for a guest).
    results_visible = results_allowed and tallies_loaded
    results_peeking = results_toggleable and tallies_loaded

    %{
      choices: choices,
      has_voted: voted?,
      counts_by_choice_id: counts_by_choice_id,
      my_votes: my_votes,
      vetoed_ids: vetoed_ids,
      score_histogram_by_choice_id: local_histograms,
      end_time: end_time,
      closed: closed,
      locked: not closed and not voted? and not results_allowed and not results_toggleable,
      results_visible: results_visible,
      results_toggleable: results_toggleable,
      results_peeking: results_peeking,
      can_load_results: results_allowed or results_toggleable,
      tallies_loaded: tallies_loaded,
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

  # A remote poll has no local tallies or own votes: its counts come from the cached object, once loaded.
  defp preview_vote_state(_question, true, _current_user, vote_state) do
    loaded = if is_map(vote_state), do: Map.get(vote_state, :tallies_loaded, true), else: false
    Map.put(Votes.empty_preview_vote_state(), :tallies_loaded, loaded)
  end

  defp preview_vote_state(question, _is_remote, _current_user, vote_state)
       when is_map(vote_state) do
    if Map.has_key?(vote_state, :counts_by_choice_id) do
      vote_state
    else
      Map.get(vote_state, id(question), Votes.empty_preview_vote_state())
    end
  end

  # Nothing passed in and nothing loaded by `update_many/1`: no own votes, no tallies, and no query.
  defp preview_vote_state(_question, _is_remote, _current_user, _vote_state),
    do: unloaded_vote_state()

  @doc "The state of a poll whose tallies are not loaded: no counts, and no own votes unless given."
  def unloaded_vote_state(my_vote_weights \\ %{}),
    do:
      Votes.empty_preview_vote_state()
      |> Map.put(:my_vote_weights, my_vote_weights)
      |> Map.put(:tallies_loaded, false)

  # A closed poll's tallies are cached with no expiry (`expire: nil`): they can't change once voting ended.
  # @closed_tallies_ttl to_timeout(day: 30)

  defp tallies_cache_key(question_id), do: "bonfire_poll:closed_tallies:#{question_id}"

  @doc "True when the viewer may load this poll's tallies now: the results policy allows them, or they may peek on an open poll. The server-side check behind \"See results\"."
  def may_load_results?(question, current_user, my_vote_weights \\ %{}) do
    state = view_state(question, false, current_user, unloaded_vote_state(my_vote_weights))
    state.can_load_results
  end

  @doc """
  The state with this poll's tallies loaded, when the viewer may see them (`may_load_results?/3`), else unchanged. A closed poll's tallies come from the cache, loaded once and kept (they can't change); an open poll's are read fresh. A remote poll has none of its own: its counts are read from the cached object when rendering.
  """
  def load_tallies(question, current_user, %{} = state, is_remote \\ false) do
    cond do
      Map.get(state, :tallies_loaded) == true ->
        state

      is_remote ->
        Map.put(state, :tallies_loaded, true)

      may_load_results?(question, current_user, Map.get(state, :my_vote_weights, %{})) ->
        tallies =
          if closed?(end_time(question)) do
            Map.get(state, :cached_tallies) || closed_tallies([question]) |> Map.get(id(question))
          else
            Votes.tallies_for_questions([question]) |> Map.get(id(question))
          end

        state
        |> Map.delete(:cached_tallies)
        |> Map.merge(tallies)
        |> Map.put(:tallies_loaded, true)

      true ->
        state
    end
  end

  # The preview's own events (`phx-target` is the component): "See results" loads this poll's tallies if the viewer may see them (`load_tallies/4` checks); voting and suggesting an option are the form submissions.
  def handle_event("show_results", _params, %{assigns: %{qstate: %{} = state}} = socket) do
    {:noreply,
     Phoenix.Component.assign(
       socket,
       :qstate,
       load_tallies(
         socket.assigns.object,
         current_user(socket),
         state,
         socket.assigns[:is_remote] == true
       )
     )}
  end

  def handle_event("hide_results", _params, %{assigns: %{qstate: %{} = state}} = socket) do
    {:noreply, Phoenix.Component.assign(socket, :qstate, unload_tallies(state))}
  end

  def handle_event("submit_vote", %{"question_id" => question} = params, socket) do
    voter = current_user(socket)

    # Guard explicitly: `Votes.vote(nil, …)` would otherwise return the
    # misleading "Voting is not open" rather than prompting a sign-in.
    case voter && Votes.vote(voter, question, Bonfire.Poll.LiveHandler.parse_votes(params)) do
      nil ->
        {:noreply, assign_error(socket, l("You need to sign in to vote."))}

      {:ok, _result} ->
        # re-read the voter's own votes, and show the tallies at once where the results policy lets a voter see them (`load_tallies/4` checks)
        state =
          unloaded_vote_state(
            Votes.my_votes_for_questions(voter, [socket.assigns.object])
            |> Map.get(id(socket.assigns.object), %{})
          )

        {:noreply,
         socket
         |> Phoenix.Component.assign(
           :qstate,
           load_tallies(
             socket.assigns.object,
             voter,
             state,
             socket.assigns[:is_remote] == true
           )
         )
         |> assign_flash(:info, l("Thanks for participating!"))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign_error(socket, msg)}

      other ->
        # Defensive: log + swallow unexpected return shapes from Votes.vote/4.
        error(other, "submit_vote: unexpected vote result")
        {:noreply, assign_error(socket, l("Sorry, you can't vote on this poll."))}
    end
  end

  def handle_event(
        "submit_proposal",
        %{"question_id" => question_id, "proposal" => %{"name" => name}},
        socket
      ) do
    case Bonfire.Poll.Choices.add_proposal(
           question_id,
           %{name: name},
           current_user: current_user(socket)
         ) do
      {:ok, _choice} ->
        # `push_navigate` to the same URL forces the LV to re-fetch the
        # question and pick up the newly-inserted choice.
        socket =
          case path_for_question(question_id, current_user: current_user(socket)) do
            nil -> socket
            path -> Phoenix.LiveView.push_navigate(socket, to: path)
          end

        {:noreply, assign_flash(socket, :info, l("Proposal added."))}

      {:error, :proposal_phase_closed} ->
        {:noreply, assign_error(socket, l("The proposal phase is not currently open."))}

      {:error, :not_authorized} ->
        {:noreply,
         assign_error(socket, l("You don't have permission to suggest options for this poll."))}

      {:error, :name_required} ->
        {:noreply, assign_error(socket, l("Please enter the option text."))}

      {:error, :unauthorized} ->
        {:noreply, assign_error(socket, l("You need to sign in first."))}

      {:error, :not_found} ->
        {:noreply, assign_error(socket, l("Poll not found."))}

      other ->
        error(other, "submit_proposal failed")
        {:noreply, assign_error(socket, l("Could not add proposal."))}
    end
  end

  defp path_for_question(id, opts) when is_binary(id) do
    case Questions.read(id, opts) do
      {:ok, q} -> path(q)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp path_for_question(_, _), do: nil

  @doc "The state with the tallies dropped again (\"Hide results\")."
  def unload_tallies(%{} = state),
    do:
      unloaded_vote_state(Map.get(state, :my_vote_weights, %{}))
      |> Map.merge(Map.take(state, [:may_see_results]))

  # The tallies of closed polls, keyed by question id: read from the cache, the misses loaded in one query and cached.
  defp closed_tallies(questions) do
    cached = read_cached_tallies(questions)

    missing = Enum.reject(questions, &Map.has_key?(cached, id(&1)))

    loaded =
      if missing == [] do
        %{}
      else
        missing
        |> Votes.tallies_for_questions()
        |> tap(fn tallies ->
          Enum.each(tallies, fn {question_id, value} ->
            Cache.put(tallies_cache_key(question_id), value,
              expire: nil,
              async: false
            )
          end)
        end)
      end

    Map.merge(cached, loaded)
  end

  # one batched cache read for all the polls
  defp read_cached_tallies(questions) do
    cached = questions |> Enum.map(&tallies_cache_key(id(&1))) |> Cache.get_many()

    for question <- questions,
        value = Map.get(cached, tallies_cache_key(id(question))),
        is_map(value),
        into: %{},
        do: {id(question), value}
  end

  @doc """
  Loads what the previews on a page need, for all of them at once: the signed-in viewer's own votes in one query (none for a guest), and the tallies of closed polls from the cache (for a guest the misses are loaded in one query and cached, and shown; a signed-in viewer's stay unshown until "See results"). A poll given a `vote_state` is left to the caller, as is one already loaded.
  """
  def update_many(assigns_sockets) do
    # `{what the poll was given, with the declared prop defaults and what it kept, socket}`
    entries =
      Enum.map(assigns_sockets, fn {assigns, socket} ->
        given =
          Bonfire.UI.Common.Web.apply_surface_prop_defaults(__MODULE__, assigns, socket)
          |> Map.drop([:__changed__, :flash])

        {given, Map.merge(socket.assigns, given), socket}
      end)

    # the polls whose state this module loads: not given a `vote_state`, not remote (its counts come from the cached object), not loaded already
    local =
      for {_given, assigns, socket} <- entries,
          is_nil(assigns[:vote_state]),
          assigns[:is_remote] != true,
          assigns[:object],
          socket.assigns[:qstate_for] != id(assigns[:object]),
          do: assigns[:object]

    current_user =
      case entries do
        [{_given, assigns, _} | _] -> current_user(assigns[:__context__])
        _ -> nil
      end

    my_votes = Votes.my_votes_for_questions(current_user, local)

    closed =
      Enum.filter(local, fn question ->
        closed?(end_time(question)) and
          may_load_results?(question, current_user, Map.get(my_votes, id(question), %{}))
      end)

    closed_tallies = if closed == [], do: %{}, else: closed_tallies_for(closed, current_user)
    closed_ids = MapSet.new(closed, &id/1)

    Enum.map(entries, fn {given, assigns, socket} ->
      object = assigns[:object]
      socket = Phoenix.Component.assign(socket, given)

      if (is_nil(assigns[:vote_state]) and object) && socket.assigns[:qstate_for] != id(object) do
        qstate =
          unloaded_vote_state(Map.get(my_votes, id(object), %{}))
          |> put_closed_tallies(Map.get(closed_tallies, id(object)), current_user)
          |> put_may_see_results(MapSet.member?(closed_ids, id(object)))

        Phoenix.Component.assign(socket, qstate: qstate, qstate_for: id(object))
      else
        socket
      end
    end)
  end

  # a guest sees a closed poll's results straight away; a signed-in viewer's wait for the click
  defp closed_tallies_for(closed, nil), do: closed_tallies(closed)
  defp closed_tallies_for(closed, _current_user), do: read_cached_tallies(closed)

  # `closed` only holds polls the viewer may see the results of (checked once in `update_many/1`), so the render need not check again
  defp put_may_see_results(state, true), do: Map.put(state, :may_see_results, true)
  defp put_may_see_results(state, _), do: state

  defp put_closed_tallies(state, nil, _current_user), do: state

  defp put_closed_tallies(state, tallies, nil),
    do: state |> Map.merge(tallies) |> Map.put(:tallies_loaded, true)

  defp put_closed_tallies(state, tallies, _current_user),
    do: Map.put(state, :cached_tallies, tallies)

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

  @doc "Calculate time remaining for a poll (pass `now` for a deterministic reference time)"
  def time_remaining(end_time, now \\ nil)

  def time_remaining(nil, _now), do: nil

  def time_remaining(end_time, now) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> time_remaining(dt, now)
      _ -> nil
    end
  end

  def time_remaining(%DateTime{} = end_time, now) do
    now = now || DateTime.utc_now()

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

  def time_remaining(_, _now), do: nil

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
  names the process rather than calling everything a "poll". (The state is shown
  separately, see `state_tone_class/1`.)
  """
  def process_kind("weighted_multiple"), do: l("Group decision")
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
  def state_label(:open, "weighted_multiple"), do: l("Ongoing")
  def state_label(:open, _format), do: l("Open")
  # Group (consent) decisions never declare a verdict — a closed one is just
  # "Closed" and each group reads the reaction results itself.
  def state_label(_state, "weighted_multiple"), do: l("Closed")
  def state_label(:decided, _format), do: l("Decided")
  def state_label(:no_consensus, _format), do: l("No consensus")
  def state_label(:no_agreement, _format), do: l("No agreement")
  def state_label(_state, _format), do: l("Closed")

  @doc """
  Text tone for the meta line's state label (and its dot, which is
  `bg-current`).
  """
  def state_tone_class(:open), do: "text-success"
  # Closed states carry no verdict colour — only the temporal open/closed
  # distinction is signalled (success while open, neutral once closed).
  def state_tone_class(_state), do: "text-muted"

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
