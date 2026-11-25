defmodule Bonfire.Poll.Web.Preview.ChoiceContentLive do
  use Bonfire.UI.Common.Web, :stateless_component

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
  prop compact, :boolean, default: false
  prop is_winner, :boolean, default: false

  def post_content(object) do
    e(object, :post_content, nil) || object
  end

  @doc "The option's text cut where it places its media (`Bonfire.Files.InlineMedia.split/3`), once, with the options `Bonfire.UI.Common.HtmlBodyPartsLive` renders it with: `%{parts, inline_media, unplaced}`, the unplaced (eg. a link in a sentence) to show under it."
  def split_media(object, name) do
    maybe_apply(
      Bonfire.Files.InlineMedia,
      :split,
      [e(object, :media, []), name, Bonfire.UI.Common.HtmlBodyPartsLive.parts_opts([])],
      fallback_return: %{parts: nil, inline_media: %{}, unplaced: []}
    )
  end
end
