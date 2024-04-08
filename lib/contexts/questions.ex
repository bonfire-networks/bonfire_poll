defmodule Bonfire.Poll.Questions do
  use Bonfire.Common.Utils
  import Bonfire.Poll.Integration
  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Choices
  alias Bonfire.Epics.Epic

  def create(options \\ []) do
    # TODO: sanitise HTML to a certain extent depending on is_admin and/or boundaries
    with {:ok, question} <- run_epic(:create, options ++ [do_not_strip_html: true]) do
      Choices.simple_create_and_put(options[:question_attrs][:choice], question, options)
      {:ok, question}
    end
  end

  def changeset(question \\ %Bonfire.Poll.Question{}, attrs) do
    Question.changeset(question, attrs)
  end

  def create_simple(%Question{} = question) do
    question
    |> changeset()
    |> create_simple()
  end

  def create_simple(%Ecto.Changeset{} = changeset) do
    changeset
    |> repo().insert()
  end

  def create_simple(%{} = attrs) do
    attrs
    |> changeset()
    |> create_simple()
  end

  def run_epic(type, options, module \\ __MODULE__, on \\ :question) do
    options = Keyword.merge(options, crash: false, debug: true, verbose: false)

    epic =
      Epic.from_config!(module, type)
      |> Epic.assign(:options, options)
      |> Epic.run()

    if epic.errors == [], do: {:ok, epic.assigns[on]}, else: {:error, epic}
  end
end
