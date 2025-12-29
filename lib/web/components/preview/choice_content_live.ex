defmodule Bonfire.Poll.Web.Preview.ChoiceContentLive do
  use Bonfire.UI.Common.Web, :stateless_component

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

  def post_content(object) do
    e(object, :post_content, nil) || object
  end
end
