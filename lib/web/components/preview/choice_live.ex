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

  @doc """
  The Block count shown beside a group decision's reaction bar.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.blocks_label(1)
      "1 block"

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.blocks_label(3)
      "3 blocks"
  """
  def blocks_label(n), do: lp("1 block", "%{count} blocks", n, count: n)

  def score_label(score) do
    Enum.find(Votes.scores(), fn {value, _name, _icon, _desc} -> value == score end)
  end

  @doc """
  The `--poll-tone-*` custom property for a reaction score. Templates colour the
  scale through these tokens rather than fixed classes, so each preset and theme
  can retune the five tones and Block in CSS alone.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.score_tone_var(2)
      "--poll-tone-great"

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.score_tone_var(-1)
      "--poll-tone-concern"

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.score_tone_var("∞")
      "--poll-tone-block"
  """
  def score_tone_var(2), do: "--poll-tone-great"
  def score_tone_var(1), do: "--poll-tone-fine"
  def score_tone_var(-1), do: "--poll-tone-concern"
  def score_tone_var(-2), do: "--poll-tone-disagree"
  def score_tone_var("∞"), do: "--poll-tone-block"
  def score_tone_var(_), do: "--poll-tone-neutral"

  @doc """
  Builds one reaction bucket from a `%{vote_weight => count}` histogram, as
  `{value, name, icon, count}`. `value` is the score (`"∞"` for Block, whose
  weight is `nil`), with name and icon from `Votes.scores/0` via `score_label/1`.
  Templates take the tone from `score_tone_var/1`.

  ## Examples

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{1 => 10, 2 => 5}, 1)
      {1, "Seems fine", "ph:smiley-fill", 10}

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{nil => 1, 2 => 4}, nil)
      {"∞", "Block", "ph:prohibit-fill", 1}

      iex> Bonfire.Poll.Web.Preview.ChoiceLive.histogram_segment(%{2 => 4}, -1)
      {-1, "Concerned", "ph:smiley-meh-fill", 0}
  """
  def histogram_segment(histogram, weight) when is_map(histogram) do
    count = Map.get(histogram, weight, 0)
    score_value = if is_nil(weight), do: "∞", else: weight
    {_v, name, icon, _desc} = score_label(score_value) || {score_value, "", "", ""}
    {score_value, name, icon, count}
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

  # The scale's buckets in order, Disagree → Agree.
  @scale_order [-2, -1, 0, 1, 2]

  @doc """
  Every reaction bucket, empty ones included, as `{scale, block}`: the scale's
  `histogram_segment/2` tuples ordered Disagree → Agree, and Block's apart (it
  sits off the agree/disagree axis: it's a veto, not a point on the scale). The
  stacked reaction bar renders every scale bucket (empty ones hidden) so the
  order stays fixed.

  ## Examples

      iex> {scale, block} = Bonfire.Poll.Web.Preview.ChoiceLive.reaction_strip(%{2 => 3, nil => 1})
      iex> Enum.map(scale, &elem(&1, 3))
      [0, 0, 0, 0, 3]
      iex> block
      {"∞", "Block", "ph:prohibit-fill", 1}
  """
  def reaction_strip(histogram) when is_map(histogram),
    do: {Enum.map(@scale_order, &histogram_segment(histogram, &1)), histogram_segment(histogram, nil)}

  def reaction_strip(_), do: reaction_strip(%{})
end
