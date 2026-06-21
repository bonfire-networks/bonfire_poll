if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Poll.API.GraphQL do
    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern

    use Bonfire.Common.E
    import Bonfire.Poll
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Pagination
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Types
    alias Bonfire.Poll.Questions
    alias Bonfire.Poll.Votes

    # import_types(Absinthe.Type.Custom)

    object :poll do
      field(:id, :id)
      field(:post_content, :post_content)

      field :choices, list_of(:choice) do
        # Load choices here because only the poll resolver has both poll and choice context.
        resolve(fn poll, _, info ->
          user = GraphQL.current_user(info)
          visible = Votes.results_visible?(nil, poll, current_user: user)

          counts =
            if visible,
              do: Votes.preview_vote_state_for_question(poll, user).counts_by_choice_id,
              else: %{}

          choices =
            poll_choices(poll)
            |> Enum.map(fn ch ->
              Map.put(
                ch,
                :votes_result_total,
                if(visible, do: Map.get(counts, ch.id, 0), else: nil)
              )
            end)

          {:ok, choices}
        end)
      end

      field(:activity, :activity)

      field :proposals_open_at, :datetime do
        resolve(fn poll, _, _ ->
          {:ok, (poll.proposal_dates || []) |> List.first()}
        end)
      end

      field :proposals_close_at, :datetime do
        resolve(fn poll, _, _ ->
          {:ok, poll.proposal_dates |> Questions.end_date()}
        end)
      end

      field :voting_open_at, :datetime do
        resolve(fn poll, _, _ ->
          {:ok, (poll.voting_dates || []) |> List.first()}
        end)
      end

      field :voting_close_at, :datetime do
        resolve(fn poll, _, _ ->
          {:ok, poll.voting_dates |> Questions.end_date()}
        end)
      end

      field :votes_count, :integer do
        resolve(fn poll, _, _ ->
          # Use the per-question read model so counts stay scoped to this poll.
          {:ok, Votes.counts_for_questions([poll.id]) |> Map.get(poll.id, 0)}
        end)
      end

      field :voters_count, :integer do
        resolve(fn poll, _, _ ->
          # Distinct voters for THIS poll (read model), not globally.
          {:ok, Votes.preview_vote_state_for_question(poll).voter_count}
        end)
      end

      field :voted, :boolean do
        # Unauthenticated requests have no current_user and should resolve false.
        resolve(fn poll, _, info ->
          user = GraphQL.current_user(info)
          {:ok, MapSet.member?(Votes.voted_question_ids(user, [poll.id]), poll.id)}
        end)
      end

      field :own_votes, list_of(:choice) do
        resolve(fn poll, _, info ->
          user = GraphQL.current_user(info)

          voted_ids =
            Votes.preview_vote_state_for_question(poll, user).my_vote_weights
            |> Map.keys()
            |> MapSet.new()

          {:ok, poll_choices(poll) |> Enum.filter(&MapSet.member?(voted_ids, &1.id))}
        end)
      end

      field :voting_format, :string
    end

    connection(node_type: :poll)

    object :choice do
      field(:id, :id)
      field(:post_content, :post_content)

      # Enriched by the poll choices resolver, where result visibility is known.
      field(:votes_result_total, :integer)
      # Kept for schema/fragment compatibility; not currently populated.
      field(:votes_result_average, :integer)
    end

    object :score do
      field(:weight, :string)
      field(:icon, :string)
      field(:name, :string)
      field(:summary, :string)
    end

    input_object :poll_filters do
      field(:id, :id)
    end

    input_object :vote_input do
      field(:choice_id, :id)
      field(:weight, :string)
    end

    object :poll_queries do
      @desc "Get all polls"
      # field :polls, list_of(:poll) do
      #   resolve(&list_polls/3)
      # end
      connection field :polls, node_type: :poll do
        # Bound query cost by requested page size so an abusive `first:`/`last:` is rejected
        # before resolution (on the public endpoint where complexity analysis is enabled).
        complexity(fn args, child -> (args[:first] || args[:last] || 20) * child + 1 end)
        resolve(&list_polls/3)
      end

      @desc "Get a poll"
      field :poll, :poll do
        arg(:filter, :poll_filters)
        resolve(&get_poll/3)
      end

      @desc "List default possible scores"
      field :default_scores, list_of(:score) do
        resolve(&list_scores/3)
      end
    end

    object :poll_mutations do
      field :create_poll, :poll do
        arg(:voting_format, :string)

        arg(:post_content, non_null(:post_content_input))

        arg(:choices, list_of(:post_content_input))

        arg(:reply_to, :id)
        arg(:boundary, :string)
        arg(:to_circles, list_of(:id))
        # Publish the poll into this group/topic (category) id — like createPost.
        arg(:context_id, :id)
        # Without a voting window the poll has nil voting_dates and cannot be voted on.
        arg(:duration_hours, :integer)

        resolve(&create_poll/2)
      end

      field :vote, :activity do
        arg(:poll_id, non_null(:string))
        arg(:votes, list_of(:vote_input))

        resolve(&vote/2)
      end
    end

    # Choices may be unpreloaded depending on the feed path.
    defp poll_choices(poll) do
      Bonfire.Common.Repo.maybe_preload(poll, choices: [:post_content])
      |> e(:choices, [])
    end

    # def list_polls(_parent, args, info) do
    #   {:ok,
    #    Questions.list_paginated(Map.to_list(args), GraphQL.current_user(info)) |> prepare_list()}
    # end
    def list_polls(_parent, args, info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)

      Questions.list_paginated(filters,
        current_user: GraphQL.current_user(info),
        pagination: pagination_args
      )
      |> Pagination.connection_paginate(pagination_args)
    end

    def list_scores(_, _, _) do
      {:ok,
       Bonfire.Poll.Votes.scores()
       |> Enum.map(fn {i, name, icon, summary} ->
         %{weight: i, name: name, icon: icon, summary: summary}
       end)}
    end

    def get_poll(_parent, %{filter: %{id: id}} = _args, info) do
      Questions.read(id, GraphQL.current_user(info))
    end

    defp create_poll(args, info) do
      current_user = GraphQL.current_user(info)

      if current_user do
        case args[:duration_hours] || 72 do
          hours when is_integer(hours) and hours > 0 ->
            now = DateTime.utc_now()

            question_attrs =
              Map.put(args, :voting_dates, [now, DateTime.add(now, hours * 3600, :second)])

            opts = [
              current_user: current_user,
              question_attrs: question_attrs
              #  boundary: e(params, "to_boundaries", "mentions")
            ]

            opts =
              if args[:context_id],
                do: opts ++ [context_id: args[:context_id]],
                else: opts

            Questions.create(opts)

          _ ->
            {:error, "duration_hours must be a positive integer"}
        end
      else
        {:error, "Not authenticated"}
      end
    end

    defp vote(%{poll_id: question, votes: votes}, info) do
      current_user = GraphQL.current_user(info)

      if not is_nil(current_user) do
        with {:ok, f} <-
               Votes.vote(
                 current_user,
                 question,
                 votes
                 |> Enum.map(fn
                   %{choice_id: choice_id, weight: weight} = map ->
                     map

                   %{choice_id: choice_id} = map ->
                     Map.put(map, :weight, 1)

                   other ->
                     error(other, "invalid input")
                     raise Bonfire.Fail, :invalid_argument
                 end)
               ),
             do: {:ok, e(f, :activity, nil) || f}
      else
        # {:error, "Not authenticated"}  
        raise(Bonfire.Fail.Auth, :needs_login)
      end
    end
  end
else
  IO.warn("Skip GraphQL API")
end
