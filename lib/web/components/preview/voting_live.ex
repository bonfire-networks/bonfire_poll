defmodule Bonfire.Poll.VotingLive do
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Votes
  alias Phoenix.LiveView.JS

  prop choice, :any, default: nil
  prop question, :any, default: nil
  prop voting_format, :string, default: nil
  prop selected, :any, default: nil
  prop readonly, :boolean, default: false
  prop scores, :list, default: nil
  prop index, :integer, default: 0
  prop id_prefix, :string, default: nil

  slot default

  defdelegate score_tone_var(score), to: Bonfire.Poll.Web.Preview.ChoiceLive

  def scores_or_default(nil), do: Votes.scores()
  def scores_or_default(scores), do: scores

  @doc """
  Splits the reaction scores into the agreement scale and Block. Block is a veto,
  not a degree of agreement, so it renders outside the scale's track while
  staying in the same radiogroup (one value per option).

  ## Examples

      iex> [{:scale, scale}, {:block, block}] = Bonfire.Poll.VotingLive.reaction_groups(nil)
      iex> Enum.map(scale, &elem(&1, 0))
      [-2, -1, 0, 1, 2]
      iex> Enum.map(block, &elem(&1, 0))
      ["∞"]
  """
  def reaction_groups(scores) do
    {block, scale} =
      scores
      |> scores_or_default()
      |> Enum.split_with(&(elem(&1, 0) == "∞"))

    [{:scale, scale}, {:block, block}]
  end

  # CSS-safe token for a sentiment score, used in element ids (no `-` or `∞`).
  def score_key(-2), do: "neg2"
  def score_key(-1), do: "neg1"
  def score_key(0), do: "z"
  def score_key(1), do: "p1"
  def score_key(2), do: "p2"
  def score_key("∞"), do: "veto"

  @doc """
  phx-click chain that records the chosen weight + flips aria-checked on its siblings, then fires `poll:reacted` (bubbling to the fieldset) so the callout reads the new pick.
  """
  def choose_weight_js(prefix, choice_id, score) do
    choose_weight_js(
      vote_dom_id(prefix, "vote-input", choice_id),
      vote_dom_id(prefix, "vote-btn", choice_id, score_key(score)),
      vote_dom_id(prefix, "vote-weight", choice_id),
      score
    )
  end

  def choose_weight_js(fieldset_id, button_id, hidden_id, score) do
    JS.set_attribute({"aria-checked", "false"}, to: "##{fieldset_id} button[role='radio']")
    |> JS.set_attribute({"aria-checked", "true"}, to: "##{button_id}")
    |> JS.set_attribute({"value", "#{score}"}, to: "##{hidden_id}")
    |> JS.dispatch("poll:reacted")
  end

  def chosen_value(false), do: ""
  def chosen_value(nil), do: ""
  def chosen_value(value), do: to_string(value)

  @doc "Builds a scoped DOM id for poll voting controls."
  def vote_dom_id(prefix, kind, choice_id, suffix \\ nil) do
    [kind, prefix, choice_id, suffix]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
  end

  @doc """
  Roving-tabindex pattern for a `role=radiogroup`: the selected button is
  tab-stop (`0`), the rest are skipped (`-1`). When nothing is selected, the
  Neutral (`0`) button becomes the tab-stop so Tab still enters the group.
  """
  def roving_tabindex(score, selected) do
    cond do
      selected && score == selected -> "0"
      !selected && score == 0 -> "0"
      true -> "-1"
    end
  end
end
