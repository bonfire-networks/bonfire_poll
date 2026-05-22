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

  prop vote, :boolean, default: false
  prop vote_count, :integer, default: 0
  prop total_votes, :integer, default: 0
  prop voted_on, :boolean, default: false
  prop user_score, :any, default: nil
  prop has_voted_overall, :boolean, default: false
  prop results_visible, :boolean, default: false
  prop is_winner, :boolean, default: false
  prop is_vetoed, :boolean, default: false
  prop closed, :boolean, default: false
  prop show_author, :boolean, default: false
  # Renders a disabled radio slot on the left as a visual preview of where
  # the vote control will land once the proposal phase closes.
  prop proposal_phase, :boolean, default: false
  prop index, :integer, default: 0
  prop compact, :boolean, default: false

  def preloads(), do: [:post_content]

  def proposer_username(choice), do: e(choice, :created, :creator, :character, :username, nil)

  def proposer_name(choice) do
    e(choice, :created, :creator, :profile, :name, nil) || proposer_username(choice)
  end

  def percent(vote_count, total) when is_integer(vote_count) and is_integer(total) and total > 0,
    do: round(vote_count * 100 / total)

  def percent(_, _), do: 0

  def score_label(score) do
    Enum.find(Votes.scores(), fn {value, _name, _icon, _desc} -> value == score end)
  end

  def score_color_class(score) when is_number(score) and score > 0, do: "text-success"
  def score_color_class(score) when is_number(score) and score < 0, do: "text-warning"
  def score_color_class("∞"), do: "text-error"
  def score_color_class(_), do: "text-base-content/70"
end
