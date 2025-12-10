defmodule Bonfire.Poll.Questions do
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  # import Bonfire.Poll
  import Bonfire.Boundaries.Queries

  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Choices
  alias Bonfire.Epics.Epic
  alias Bonfire.Social.Objects

  def default_voting_format, do: Config.get([:bonfire_poll, :default_voting_format], "single")

  def create(options \\ []) do
    # TODO: sanitise HTML to a certain extent depending on is_admin and/or boundaries

    with {:ok, question} <- run_epic(:create, options ++ [do_not_strip_html: true]) do
      Choices.simple_create_and_put(options[:question_attrs][:choices] || [], question, options)
      |> debug("choices added")

      {:ok,
       question
       # TODO: use data we already have
       |> repo().maybe_preload(choices: [:post_content])}
    end
  end

  def run_epic(type, options, module \\ __MODULE__, on \\ :question) do
    Bonfire.Epics.run_epic(module, type, Keyword.put(options, :on, on))
  end

  def changeset(question \\ %Bonfire.Poll.Question{}, attrs) do
    # Ensure voting_format is present in question_attrs or set to default
    attrs =
      attrs
      |> Map.put_new(:voting_format, default_voting_format())

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

  def read(post_id, opts_or_socket_or_current_user \\ [])
      when is_binary(post_id) do
    query([id: post_id], opts_or_socket_or_current_user)
    |> Objects.read(opts_or_socket_or_current_user)
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts \\ []) do
    # query FeedPublish
    # [posts_by: {by_user, &filter/3}]
    Objects.maybe_filter(query_base(), {:creators, by_user})
    |> list_paginated(to_options(opts) ++ [subject_user: by_user])
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts \\ [])

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    filters
    # |> debug("filters")
    |> query_paginated(opts)
    |> Objects.list_paginated(opts)
    |> debug()
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts \\ [])

  def query_paginated([], opts), do: query_paginated(query_base(), opts)

  def query_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    Objects.list_query(filters, opts)
    # |> proload([:post_content])  
  end

  # query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [],  query \\ FeedPublish)
  def query_paginated({a, b}, opts), do: query_paginated([{a, b}], opts)

  def query(filters \\ [], opts \\ nil)

  def query(filters, opts) when is_list(filters) or is_tuple(filters) do
    query_base()
    |> query_filter(filters, nil, nil)
    |> boundarise(main_object.id, opts)
  end

  defp query_base do
    from(main_object in Question, as: :main_object)
    |> proload([:post_content, choices: {"choice_", [:post_content]}])
  end
end
