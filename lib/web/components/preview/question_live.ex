defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Common.Text

  prop object, :any
  prop activity_component_id, :any, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  # prop activity_inception, :any, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop thread_title, :any, default: nil
  # prop thread_mode, :atom, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  def preloads(),
    do: [
      :post_content,
      # :voted,
      choices: [:post_content, object_voted: [:vote]]
    ]

  def post_content(object) do
    # |> debug("activity_question_object")
    (object
     |> e(:post_content, nil) || object)
    |> debug()
  end

  def maybe_truncate(input, skip \\ false, length \\ 800)

  def maybe_truncate(input, skip, length) when skip != true and is_binary(input) do
    Text.sentence_truncate(input, length, "...")
  end

  def maybe_truncate(input, _skip, _length), do: input

  @doc "Calculate total votes count across all choices"
  def total_votes(choices) when is_list(choices) do
    choices
    |> Enum.map(&choice_vote_count/1)
    |> Enum.sum()
  end

  def total_votes(_), do: 0

  @doc "Calculate unique voters count"
  def voters_count(choices) when is_list(choices) do
    choices
    |> Enum.flat_map(fn choice ->
      case e(choice, :object_voted, nil) do
        votes when is_list(votes) -> Enum.map(votes, & &1.subject_id)
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> length()
  end

  def voters_count(_), do: 0

  @doc "Get vote count for a single choice"
  def choice_vote_count(choice) do
    case e(choice, :object_voted, nil) do
      votes when is_list(votes) -> length(votes)
      _ -> 0
    end
  end

  @doc "Calculate percentage for a choice"
  def choice_percentage(choice, total) when total > 0 do
    count = choice_vote_count(choice)
    round(count * 100 / total)
  end

  def choice_percentage(_, _), do: 0
end
