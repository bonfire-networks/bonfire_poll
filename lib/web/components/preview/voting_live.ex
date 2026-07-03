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
  prop compact, :boolean, default: false
  # When true, render without the outer border-t and wrapper padding so the
  # parent can place the strip on the same row as the choice content.
  prop inline, :boolean, default: false
  prop index, :integer, default: 0
  prop id_prefix, :string, default: nil

  slot default

  defdelegate score_color_class(score), to: Bonfire.Poll.Web.Preview.ChoiceLive

  def scores_or_default(nil), do: Votes.scores()
  def scores_or_default(scores), do: scores

  # CSS-safe token for a sentiment score, used in element ids (no `-` or `∞`).
  def score_key(-2), do: "neg2"
  def score_key(-1), do: "neg1"
  def score_key(0), do: "z"
  def score_key(1), do: "p1"
  def score_key(2), do: "p2"
  def score_key("∞"), do: "veto"

  @doc "phx-click chain that records the chosen weight + flips aria-checked on its siblings."
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
