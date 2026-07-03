defmodule Bonfire.Poll.Web.Preview.ChoiceLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.ChoiceContentLive
  alias Bonfire.Poll.VotingLive

  prop object, :any
  prop question, :any, default: nil
  prop voting_format, :string, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false
  prop id_prefix, :string, default: nil

  prop vote, :boolean, default: false
  prop vote_count, :integer, default: 0
  prop total_votes, :integer, default: 0
  prop voted_on, :boolean, default: false
  prop user_score, :any, default: nil
  prop results_visible, :boolean, default: false
  prop is_winner, :boolean, default: false
  prop is_vetoed, :boolean, default: false
  prop show_author, :boolean, default: false
  # Renders a disabled radio slot on the left as a visual preview of where
  # the vote control will land once the proposal phase closes.
  prop proposal_phase, :boolean, default: false
  prop index, :integer, default: 0
  prop compact, :boolean, default: false
  prop score_histogram, :any, default: %{}
  prop voters_count, :integer, default: 0

  def preloads(), do: [:post_content]

  def proposer_username(choice), do: e(choice, :created, :creator, :character, :username, nil)

  def proposer_name(choice) do
    e(choice, :created, :creator, :profile, :name, nil) || proposer_username(choice)
  end

  def percent(vote_count, total) when is_integer(vote_count) and is_integer(total) and total > 0,
    do: round(vote_count * 100 / total)

  def percent(_, _), do: 0

  @doc """
  The share to render on a tally bar, honest to the poll's format.

  For `"multiple"` (pick several), the denominator is the count of distinct
  voters, so a bar reads "share of voters who picked this option" — these
  correctly do not sum to 100% across options. For `"single"` each voter casts
  exactly one vote, so distinct voters equals total votes and the result is the
  plain vote share. Falls back to the total-votes denominator when the voter
  count is unknown (e.g. remote polls).

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.tally_percent("multiple", 8, 12, 10)
      80
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.tally_percent("single", 3, 12, 12)
      25
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.tally_percent("multiple", 8, 12, 0)
      67
  """
  def tally_percent("multiple", vote_count, _total_votes, voters_count)
      when is_integer(voters_count) and voters_count > 0,
      do: percent(vote_count, voters_count)

  def tally_percent(_format, vote_count, total_votes, _voters_count),
    do: percent(vote_count, total_votes)

  @doc """
  Localised, singular-aware reaction count for a consent option: `1 reaction` /
  `N reactions`. Distinct from a tally "vote": a consent option collects
  reactions (agree / concern / block), it is not a count of votes "for" it.
  """
  def reactions_label(n), do: lp("1 reaction", "%{count} reactions", n, count: n)

  def score_label(score) do
    Enum.find(Votes.scores(), fn {value, _name, _icon, _desc} -> value == score end)
  end

  def score_color_class(score) when is_number(score) and score > 0, do: "text-success"
  # Figma renders the two negatives in the red family, not amber: Concerned reads
  # as the lighter pink (secondary), Disagree as full red (error).
  def score_color_class(-1), do: "text-secondary"
  def score_color_class(score) when is_number(score) and score < 0, do: "text-error"
  def score_color_class("∞"), do: "text-error"
  def score_color_class(_), do: "text-muted"

  @doc """
  True when there is at least one reaction to chart for this choice.
  """
  def has_histogram?(histogram) when is_map(histogram), do: map_size(histogram) > 0
  def has_histogram?(_), do: false

  @doc """
  Builds one reaction chip for a `vote_weight` bucket from a `%{vote_weight =>
  count}` histogram, as `{value, name, icon, color_class, count}`. `value` is the
  raw weight (`nil` for Block, shown as the `"∞"` score), reusing `Votes.scores/0`
  (via `score_label/1`) for name/icon and `score_color_class/1` for the tone.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{1 => 10, 2 => 5}, 1)
      {1, "Seems fine", "ph:smiley-fill", "text-success", 10}

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{nil => 1, 2 => 4}, nil)
      {"∞", "Block", "ph:prohibit-fill", "text-error", 1}

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{2 => 4}, -1)
      {-1, "Concerned", "ph:smiley-meh-fill", "text-secondary", 0}
  """
  def histogram_segment(histogram, weight) when is_map(histogram) do
    count = Map.get(histogram, weight, 0)
    score_value = if is_nil(weight), do: "∞", else: weight
    {_v, name, icon, _desc} = score_label(score_value) || {score_value, "", "", ""}
    {score_value, name, icon, score_color_class(score_value), count}
  end

  @doc """
  True when the viewer's own reaction (`user_score`) falls in this bucket,
  so the template can mark their segment. Only meaningful when they voted.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_in_bucket?(true, 2, 2)
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_in_bucket?(true, "∞", "∞")
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_in_bucket?(false, 2, 2)
      false
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_in_bucket?(true, 0, 1)
      false
  """
  def viewer_in_bucket?(voted_on, user_score, bucket_value),
    do: voted_on == true and not is_nil(user_score) and user_score == bucket_value

  # The buckets in scale order, Disagree → Agree, with Block last (it sits off
  # the agree/disagree axis: it's a veto, not a point on the scale).
  @chip_order [-2, -1, 0, 1, 2, nil]

  @doc """
  Agree↔disagree balance for an option's reaction histogram, as the data a
  diverging bar needs. Returns counts per side plus `neg_pct`/`pos_pct`: each
  side's fill as a percentage of its half of the track, **scaled by the larger
  side** so the two fills stay in honest proportion to each other (the bigger
  side fills its half; the smaller is proportional). Block and Neutral are
  counted but kept off the agree/disagree fill.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.consent_distribution(%{2 => 3, -1 => 1, 0 => 1, nil => 1})
      %{neg_count: 1, pos_count: 3, neutral_count: 1, block_count: 1, total: 6, neg_pct: 33, pos_pct: 100}

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.consent_distribution(%{1 => 2, 2 => 2})
      %{neg_count: 0, pos_count: 4, neutral_count: 0, block_count: 0, total: 4, neg_pct: 0, pos_pct: 100}
  """
  def consent_distribution(histogram) when is_map(histogram) do
    neg = Map.get(histogram, -2, 0) + Map.get(histogram, -1, 0)
    pos = Map.get(histogram, 1, 0) + Map.get(histogram, 2, 0)
    neutral = Map.get(histogram, 0, 0)
    block = Map.get(histogram, nil, 0)
    max_side = max(neg, pos)

    %{
      neg_count: neg,
      pos_count: pos,
      neutral_count: neutral,
      block_count: block,
      total: neg + pos + neutral + block,
      neg_pct: side_pct(neg, max_side),
      pos_pct: side_pct(pos, max_side)
    }
  end

  defp side_pct(_count, 0), do: 0
  defp side_pct(count, max_side), do: round(count * 100 / max_side)

  @doc """
  True when the diverging bar is worth drawing for a `consent_distribution/1`
  result: enough reactions (≥3) and an actual agree/disagree signal. Below that —
  a single reaction, an all-neutral option — a proportional bar reads as a
  meaningless slab (or a loading skeleton), so the template shows reaction chips
  instead. Takes the already-computed distribution so the gate and the bar share
  one `consent_distribution/1` call.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_distribution_bar?(%{total: 1, neg_count: 0, pos_count: 1})
      false
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_distribution_bar?(%{total: 5, neg_count: 2, pos_count: 3})
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_distribution_bar?(%{total: 3, neg_count: 0, pos_count: 0})
      false
  """
  def show_distribution_bar?(%{total: total, neg_count: neg, pos_count: pos}),
    do: total >= 3 and (neg > 0 or pos > 0)

  def show_distribution_bar?(_), do: false

  @doc """
  The present reaction buckets as chips, ordered Disagree → Agree → Block.
  Each is the `histogram_segment/2` tuple `{value, name, icon, color, count}`;
  empty buckets are dropped.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.reaction_chips(%{2 => 3, nil => 1})
      [{2, "Great", "ph:smiley-wink-fill", "text-success", 3}, {"∞", "Block", "ph:prohibit-full", "text-error", 1}]
  """
  def reaction_chips(histogram) when is_map(histogram) do
    @chip_order
    |> Enum.map(&histogram_segment(histogram, &1))
    |> Enum.filter(fn {_v, _n, _i, _c, count} -> count > 0 end)
  end

  def reaction_chips(_), do: []

  @doc """
  True when the viewer's own reaction falls on the given side of the diverging
  bar (`:neg` for disagreement, `:pos` for agreement), so that side's fill can
  be marked. Only meaningful when they reacted.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_on_side?(true, 2, :pos)
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_on_side?(true, -2, :neg)
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_on_side?(true, 2, :neg)
      false
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.viewer_on_side?(false, 2, :pos)
      false
  """
  def viewer_on_side?(true, score, :pos) when is_number(score) and score > 0, do: true
  def viewer_on_side?(true, score, :neg) when is_number(score) and score < 0, do: true
  def viewer_on_side?(_voted_on, _score, _side), do: false

  @doc """
  Whether to render the explicit "Your reaction: …" line. Suppressed only in the
  thread chips view, where each chip already marks the viewer's own reaction —
  everywhere else (the bar view, the feed) it's the viewer's only marker.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_your_reaction_line?(true, true, %{2 => 1})
      false
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_your_reaction_line?(true, true, %{2 => 3, -1 => 2})
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_your_reaction_line?(false, true, %{2 => 1})
      true
      iex> Bonfire.Poll.Web.Preview.ChoiceLive.show_your_reaction_line?(true, false, %{})
      false
  """
  def show_your_reaction_line?(viewing_main_object, voted_on, histogram) do
    cond do
      voted_on != true ->
        false

      viewing_main_object == true and has_histogram?(histogram) and
          not show_distribution_bar?(consent_distribution(histogram)) ->
        false

      true ->
        true
    end
  end

  @doc ~S"""
  Localised, singular-aware count fragments for a consent distribution. Keeping
  the count and noun inside one `lp` call lets translators control word order
  and plurals instead of hardcoding `"<n> <word>"`.
  """
  def agree_label(n), do: lp("1 agree", "%{count} agree", n, count: n)
  def disagree_label(n), do: lp("1 disagree", "%{count} disagree", n, count: n)
  def neutral_label(n), do: lp("1 neutral", "%{count} neutral", n, count: n)
  def block_label(n), do: lp("1 block", "%{count} block", n, count: n)

  @doc "Screen-reader summary of a consent distribution, e.g. \"3 agree, 1 disagree\"."
  def consent_distribution_label(%{} = d) do
    [
      {d.pos_count, &agree_label/1},
      {d.neg_count, &disagree_label/1},
      {d.neutral_count, &neutral_label/1},
      {d.block_count, &block_label/1}
    ]
    |> Enum.filter(fn {n, _label_fn} -> n > 0 end)
    |> Enum.map_join(", ", fn {n, label_fn} -> label_fn.(n) end)
  end
end
