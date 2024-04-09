defmodule Bonfire.Poll.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Untangle

  # alias Bonfire.Data.Social.PostContent
  alias Bonfire.Poll.{Questions, Question}
  alias Bonfire.Poll.{WeightSelector, PhaseSelector}

  # alias Ecto.Changeset

  def negative_score_info do
    l("""
    When someone asks a question on Bonfire, they can choose how much weight negative scores carry. Think of it like a volume knob for disagreement. 

    > For example, if one person disagrees with a proposal and gives it -3, while another person agrees with a score of 3, increasing the negative score weighting to x3 would give us -6 instead of a meaningless 0.

    Why does this matter? It's about aiming for consent, instead of settling for everyone kinda-sorta agreeing. By giving more power to negative scores, we're saying "let's prioritize proposals that everyone can live with." Finding the sweet spot for each community or different types of decision might take a bit of experimentation, but that's part of the fun! 
    """)
  end

  # %{
  #   "_csrf_token" => "Hmled3oGBDQXAyoGKC01bjguHQ5_FkwoqY-5-IvwZQd0mcM1aVTFOZaw",
  #   "choice" => %{
  #     "0" => %{"description" => "one", "name" => "1"},
  #     "1" => %{
  #       "description" => "Keep things the way they are.",
  #       "name" => "Keep things the way they are."
  #     }
  #   },
  #   "context_id" => "",
  #   "create_object_type" => "poll",
  #   "id" => "",
  #   "name" => "",
  #   "phase" => "full",
  #   "post" => %{"post_content" => %{"html_body" => "text\n"}},
  #   "question" => %{
  #     "post_content" => %{"_persistent_id" => "0", "name" => "test poll"}
  #   },
  #   "reply_to" => %{"reply_to_id" => "", "thread_id" => ""},
  #   "to_boundaries" => ["public"],
  #   "weighting" => "1"
  # }
  def handle_event("create_poll", %{"post" => post_params} = params, socket) do
    handle_event("create_poll", Map.merge(params, post_params) |> Map.drop(["post"]), socket)
  end

  def handle_event("create_poll", %{"question" => question_params} = params, socket) do
    handle_event(
      "create_poll",
      Map.merge(params, question_params) |> Map.drop(["question"]),
      socket
    )
  end

  def handle_event("create_poll", params, socket) do
    attrs =
      params
      |> input_to_atoms(also_discard_unknown_nested_keys: false)

    current_user = current_user_required!(socket)

    with %{valid?: true} <- Question.changeset(attrs),
         #  uploaded_media <-
         #    live_upload_files(
         #      current_user,
         #      params["upload_metadata"],
         #      socket
         #    ),
         #  attrs <- Map.put(attrs, :uploaded_media, uploaded_media),
         opts <-
           [
             current_user: current_user,
             question_attrs: attrs,
             boundary: e(params, "to_boundaries", "mentions")
           ]
           |> debug("use opts for boundary + save field in PostContent"),
         {:ok, published} <- Questions.create(opts) do
      published
      |> repo().maybe_preload([:post_content])
      |> debug("created!")

      # activity = e(published, :activity, nil)

      permalink = path(published)
      # |> debug("permalink")

      {
        :noreply,
        socket
        |> assign_flash(
          :info,
          "#{l("Created!")}"
        )
        |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
        |> redirect_to(permalink)
      }
    else
      e ->
        e = Errors.error_msg(e)
        error(e)

        {
          :noreply,
          socket
          |> assign_flash(:error, "Could not create 😢 (#{e})")
          # |> patch_to(current_url(socket), fallback: "/error") # so the flash appears
        }
    end
  end

  def handle_event("add_proposal", %{"name" => name, "description" => description}, socket) do
    # Logic to handle adding a proposal goes here
    {:noreply,
     socket
     |> assign(
       :proposals,
       socket.assigns[:proposals] ++ [%{name: name, description: description}]
     )}
  end

  def handle_event("add_proposal", _params, socket) do
    # Logic to handle adding a proposal goes here
    {:noreply,
     socket
     |> assign(:proposals, socket.assigns[:proposals] ++ [%{}])}
  end

  def handle_event("add_choices", params, socket) do
    attrs =
      params
      |> Map.merge(e(params, "choice", %{}))
      |> debug("section params")
      |> input_to_atoms()

    # |> debug("post attrs")

    # debug(e(socket.assigns, :showing_within, nil), "SHOWING")

    page_id = e(attrs, :reply_to, :thread_id, nil)

    # with  
    #  uploaded_media <-
    #    live_upload_files(
    #      current_user,
    #      params["upload_metadata"],
    #      socket
    #    ),
    #  attrs <- Map.put(attrs, :uploaded_media, uploaded_media),
    with opts <-
           [
             current_user: current_user_required!(socket),
             choice_attrs: attrs,
             boundary: e(params, "to_boundaries", "mentions"),
             # to edit
             question_id: e(params, "id", nil),
             page_id: page_id
           ]
           |> debug("use opts for boundary + save fields in PostContent"),
         {:ok, _published} <- Bonfire.Poll.Choices.upsert(opts) do
      # published
      # |> repo().maybe_preload([:post_content])
      # |> dump("created!")

      {
        :noreply,
        socket
        |> assign_flash(
          :info,
          l("Choices saved!")
        )
        |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
        # |> assign(reload: Text.random_string())
        # current_url(socket), fallback: path(published))
        # |> patch_to("/pages/edit/#{page_id}?reload=#{Text.random_string()}")
      }
    else
      e ->
        e = Errors.error_msg(e)
        error(e)

        {
          :noreply,
          socket
          |> assign_flash(:error, "Could not add choices 😢 (#{e})")
          # |> patch_to(current_url(socket), fallback: "/error") # so the flash appears
        }
    end
  end

  def handle_event("add_choice", %{"choice_id" => choice_id} = params, socket) do
    question = e(socket.assigns, :object, nil) || e(params, "question_id", nil)

    Bonfire.Poll.Choices.put_choice(ulid!(choice_id), ulid!(question))
    |> debug("put_choice")

    {
      :noreply,
      socket
      |> assign_flash(
        :info,
        l("Added!")
      )
      |> assign(reload: Text.random_string())
      # |> patch_to(current_url(socket), fallback: path(question))
    }
  end

  def handle_event("remove_section", %{"choice_id" => choice_id} = params, socket) do
    question = e(socket.assigns, :object, nil) || e(params, "question_id", nil)

    Bonfire.Poll.Choices.remove_choice(ulid!(choice_id), ulid!(question))
    |> debug("remove_choice")

    {
      :noreply,
      socket
      |> assign_flash(
        :info,
        l("Removed!")
      )
      # |> assign(reload: Text.random_string())
      |> patch_to(current_url(socket), fallback: path(question))
    }
  end

  def handle_event("submit_vote", %{"question_id" => question, "vote" => votes}, socket) do
    # Logic to handle vote submission - TODO: optimise

    with {:ok, _result} <- Bonfire.Poll.Votes.vote(current_user(socket), question, votes) do
      {:noreply,
       socket
       |> assign_flash(:info, l("Thanks for participating!"))}
    end
  end
end
