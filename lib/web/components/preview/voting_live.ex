defmodule Bonfire.Poll.VotingLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop choice, :any, default: nil
  prop question, :any, default: nil
  prop voting_format, :string, default: nil
  prop selected, :any, default: nil
  prop readonly, :boolean, default: false
  prop scores, :list, default: nil

  slot default
end
