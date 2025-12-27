defmodule Bonfire.Poll.Web.Preview.ChoiceLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Common.Text

  prop object, :any
  prop question, :any, default: nil
  prop voting_format, :string, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  # prop activity_inception, :any, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  # prop thread_mode, :atom, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  prop vote, :boolean, default: false
  prop vote_count, :integer, default: 0
  prop total_votes, :integer, default: 0

  def preloads(),
    do: [
      :post_content
    ]
end
