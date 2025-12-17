defmodule Bonfire.Poll.Questions do
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  # import Bonfire.Poll
  import Bonfire.Boundaries.Queries

  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Choices
  alias Bonfire.Poll.Votes
  alias Bonfire.Epics.Epic
  alias Bonfire.Social.Objects

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Question
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Question",
      {"Update", "Question"}
    ]

  def default_voting_format, do: Config.get([:bonfire_poll, :default_voting_format], "single")

  def create(options \\ []) do
    # TODO: sanitise HTML to a certain extent depending on is_admin and/or boundaries

    with {:ok, question} <- run_epic(:create, options ++ [do_not_strip_html: true]) do
      # #  TODO: add in an Epic instead?
      # Choices.simple_create_and_put(options[:question_attrs][:choices] || [], question, options)
      # |> debug("choices added")

      {:ok,
       question
       # TODO: use data we already have
       |> repo().maybe_preload(choices: [:post_content])}
    end
  end

  defp run_epic(type, options, module \\ __MODULE__, on \\ :question) do
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
    |> repo().maybe_preload(choices: [:post_content])
  end

  @doc "Returns true if voting is currently open for the poll."
  def voting_open?(%Question{voting_dates: voting_dates}) do
    now = DateTime.utc_now()

    case voting_dates do
      [start, end_dt] when not is_nil(start) and not is_nil(end_dt) ->
        DateTime.compare(now, start) != :lt and DateTime.compare(now, end_dt) == :lt

      [start | _] when not is_nil(start) ->
        DateTime.compare(now, start) != :lt

      _ ->
        false
    end
  end

  @doc "Returns true if voting has ended for the poll."
  def voting_ended?(%Question{voting_dates: voting_dates}) do
    case end_date(voting_dates) do
      nil -> false
      end_dt -> DateTime.compare(DateTime.utc_now(), end_dt) == :gt
    end
  end

  @doc "Returns true if proposal period is currently open for the poll."
  def proposal_open?(%Question{proposal_dates: proposal_dates}) do
    now = DateTime.utc_now()

    case proposal_dates do
      [start, end_dt] when not is_nil(start) and not is_nil(end_dt) ->
        DateTime.compare(now, start) != :lt and DateTime.compare(now, end_dt) == :lt

      [start | _] when not is_nil(start) ->
        DateTime.compare(now, start) != :lt

      _ ->
        false
    end
  end

  @doc "Returns true if proposal period has ended for the poll."
  def proposal_ended?(%Question{proposal_dates: proposal_dates}) do
    case end_date(proposal_dates) do
      nil -> false
      end_dt -> DateTime.compare(DateTime.utc_now(), end_dt) == :gt
    end
  end

  def end_date([_start, end_date]), do: end_date
  def end_date(_), do: nil

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

    # |> debug()
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
    |> proload([:post_content])

    # , choices: {"choice_", [:post_content]}
  end

  def get_by_uri(uri, opts \\ []) do
    # WIP: Find question by canonical URL
    Bonfire.Federate.ActivityPub.Peered.get_by_uri(uri)
    ~> Enums.id()
    ~> read(opts)
  end

  @doc """
  Serializes a poll question as an ActivityStreams Question object and wraps in a Create/Update activity for federation.

  ## Parameters
  - subject: who is performing the action
  - verb: :create or :update
  - question: poll question struct
  """
  def ap_publish_activity(subject, verb, question) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: subject)

    # Preload choices and votes
    question =
      question
      |> repo().maybe_preload(choices: [:post_content])
      |> debug("preloaded question for ap_publish_activity")

    choices = question.choices || []

    # Determine voting format and options key
    options_key =
      case question.voting_format || default_voting_format() do
        "single" -> "oneOf"
        "multiple" -> "anyOf"
        "weighted_multiple" -> "anyOf"
      end

    # Build choices array
    options =
      Enum.map(choices, fn choice ->
        name = e(choice, :post_content, :name, nil)
        summary = e(choice, :post_content, :summary, nil)
        content = e(choice, :post_content, :html_body, nil)

        #  TODO: avoid n+1
        vote_count =
          with {:ok, votes} <- Votes.for_choice(choice, current_user: subject) do
            votes = choice.votes || []
            # FIXME: should we instead do a weighted count if necessary?
            Enum.count(votes, fn v -> v.choice_id == choice.id end)
          end

        %{
          "type" => "Note",
          "name" => name || summary || content,
          "summary" => if(name, do: summary),
          "content" => if(name || summary, do: content),
          "replies" => %{
            "type" => "Collection",
            "totalItems" => vote_count
          }
        }
      end)

    # Distinct voters count
    # voters_count = votes |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()

    # TODO
    cc = []

    # Use PostContents.ap_prepare_object_note for main content
    main_obj =
      Bonfire.Social.PostContents.ap_prepare_object_note(
        actor,
        verb,
        question,
        actor,
        # TODO: mentions (empty for now)
        [],
        # TODO: context
        nil,
        # TODO: reply_to
        nil
      )

    # Compose Question object, merging main_obj and poll-specific fields
    question_obj =
      main_obj
      |> Map.merge(%{
        "type" => "Question",
        "id" => URIs.canonical_url(question),
        "endTime" => DatesTimes.to_iso8601(end_date(question.voting_dates || [])),
        "closed" =>
          if(voting_ended?(question),
            do: DatesTimes.to_iso8601(end_date(question.voting_dates || []))
          )
        # "votersCount" => voters_count # TODO!
      })
      |> Map.put(options_key, options)
      |> debug("composed question_obj")

    # Boundary/circle logic (reuse from Posts)
    is_public = Bonfire.Boundaries.object_public?(question)

    interaction_policy =
      Bonfire.Federate.ActivityPub.AdapterUtils.ap_prepare_outgoing_interaction_policy(
        actor,
        question
      )

    to = if is_public, do: [Bonfire.Federate.ActivityPub.AdapterUtils.public_uri()], else: []

    params =
      %{
        pointer: question.id,
        local: true,
        actor: actor,
        #  TODO: we should prob publish during proposal period too?
        published: DatesTimes.to_iso8601(List.first(question.voting_dates || [])),
        to: to,
        additional: %{"cc" => cc || []},
        object:
          Map.merge(question_obj, %{
            "to" => to,
            "cc" => cc || [],
            "interactionPolicy" => interaction_policy
          })
      }
      |> debug("ap activity params")

    ap_create_or_update_activity(verb, params)
  end

  defp ap_create_or_update_activity(:update, params), do: ActivityPub.update(params)
  defp ap_create_or_update_activity(_, params), do: ActivityPub.create_intransitive(params)

  @doc """
  Receives an incoming ActivityPub Question (poll) activity and creates/updates the local poll question.

  ## Parameters
  - creator: the actor creating/updating the poll
  - activity: the AP activity
  - object: the AP Question object
  """
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Question"} = question_data} = activity,
        _object
      ) do
    attrs = ap_question_attrs(question_data)
    opts = ap_receive_opts(creator, activity, question_data, attrs)

    create(opts)
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => type} = activity_data} = activity,
        %{"id" => ap_id} = question_data
      )
      when type in ["Create", "Update"] do
    attrs = ap_question_attrs(question_data)
    opts = ap_receive_opts(creator, activity, question_data, attrs)

    case type do
      "Create" ->
        create(opts)

      "Update" ->
        with {:ok, question} <- get_by_uri(ap_id, current_user: creator),
             # TODO: also update circles/boundaries if changed?
             {:ok, question} <-
               update_question_and_choices(creator, question, opts[:question_attrs]) do
          {:ok, question}
        end
    end
  end

  def ap_receive_activity(
        creator,
        activity,
        %{data: question_data}
      ) do
    ap_receive_activity(creator, activity, question_data)
  end

  def update_question_and_choices(creator, %Question{} = question, attrs) do
    with {:ok, question} <- update_question(creator, question, Map.delete(attrs, :choices)),
         {:ok, question} <- update_choices(creator, question, attrs[:choices]) do
      {:ok, question}
    end
  end

  def update_choices(creator, %Question{} = question, choices) do
    with {:ok, _} <-
           Bonfire.Poll.Choices.simple_create_and_put(nil, choices || [], question,
             current_user: creator
           ) do
      # TODO: reload question with updated choices, or add them to the existing struct?
      {:ok, question}
    end
  end

  def update_question(_creator, %Question{} = question, attrs) do
    # TODO: check permission?
    question
    |> changeset(attrs)
    |> repo().update()
  end

  # Shared logic for mapping AP Question data to local attrs
  defp ap_question_attrs(question_data) do
    options_key =
      cond do
        Map.has_key?(question_data, "oneOf") -> "oneOf"
        Map.has_key?(question_data, "anyOf") -> "anyOf"
        true -> nil
      end

    # Map ActivityPub fields to Bonfire schema fields
    choices =
      if options_key do
        Enum.map(question_data[options_key], fn opt ->
          %{
            post_content: %{name: opt["name"], summary: opt["summary"], html_body: opt["content"]},
            vote_count: opt["replies"]["totalItems"]
          }
        end)
      else
        []
      end

    # Compose voting_dates: [start, end]
    start_time = DatesTimes.to_date_time(question_data["published"])

    end_time =
      if question_data["endTime"],
        do:
          DatesTimes.to_date_time(question_data["endTime"]) ||
            DatesTimes.to_date_time(question_data["closed"])

    %{
      post_content: %{
        name: question_data["name"],
        summary: question_data["summary"],
        html_body: question_data["content"]
      },
      voting_dates: [start_time, end_time],
      voting_format: if(options_key == "oneOf", do: "single", else: "multiple"),
      voters_count: question_data["votersCount"],
      choices: choices
    }
  end

  # Shared logic for boundary/circle/recipients extraction
  defp ap_receive_opts(creator, activity, question_data, attrs) do
    is_public = Bonfire.Federate.ActivityPub.AdapterUtils.is_public?(activity)

    direct_recipients =
      Bonfire.Federate.ActivityPub.AdapterUtils.all_known_recipient_characters(question_data)

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.recipients_boundary_circles(
        direct_recipients,
        activity,
        is_public,
        question_data["interactionPolicy"]
      )

    [
      current_user: creator,
      to_circles: to_circles,
      boundary: boundary,
      question_attrs: attrs
    ]
  end
end
