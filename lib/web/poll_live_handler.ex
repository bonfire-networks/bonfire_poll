defmodule Bonfire.Poll.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Untangle

  alias Bonfire.Poll.{Questions, Presets}
  alias Bonfire.Common.Types

  # `path_for_question/2` moved to `Bonfire.Poll.Web.Preview.QuestionLive`, with "submit_proposal"

  defp preset_params_from_form(params) do
    tuning = Map.new(Presets.tuning_keys(), &{&1, parse_bool(params["poll_tuning_#{&1}"])})

    %{
      preset: params["poll_preset"],
      tuning: tuning,
      duration_hours: Types.maybe_to_integer(params["poll_duration_hours"], nil),
      proposal_duration_hours:
        Types.maybe_to_integer(params["poll_proposal_duration_hours"], nil),
      multiple_choice: parse_bool(params["poll_multiple_choice"])
    }
  end

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  # Composer's hidden inputs that aren't backend Question attrs (dropped before cast).
  defp preset_form_keys do
    base = ~w(poll_preset poll_duration_hours poll_proposal_duration_hours poll_multiple_choice)
    base ++ Enum.map(Presets.tuning_keys(), &"poll_tuning_#{&1}")
  end

  def negative_score_info do
    l("""
    When someone asks a question, they can choose how much weight negative scores carry. Think of it like a volume knob for disagreement.

    > For example, if one person disagrees with a proposal and gives it -2, while another person agrees with a score of 2, increasing the negative score weighting to x2 would give us `(-2 x 2) + 2 = -2` instead of a meaningless `-2 + 2 = 0`.

    Why does this matter? It's about aiming for consent, instead of settling for everyone kinda-sorta agreeing. By giving more power to negative scores, we're saying "let's prioritize proposals that everyone can live with." Finding the sweet spot for each community or different types of decision might take a bit of experimentation, but that's part of the fun!
    """)
  end

  defp create_poll(params, attrs, uploaded_media, preset_params, current_user, socket) do
    # a file an option shows is attached to that option's choice, else to the question (by the poll's epic, `AttachMedia`)
    {attrs, question_media} = media_to_choices(attrs, uploaded_media)
    attrs = Map.put(attrs, :uploaded_media, question_media)

    # Reuse the post composer's audience/verb-grants plumbing.
    {final_to_circles, verb_grants} =
      maybe_apply(Bonfire.Posts.LiveHandler, :transform_circles_for_backend, [params],
        fallback_return: {[], []}
      )

    boundary = e(params, "to_boundaries", nil) |> List.wrap() |> List.first()

    with opts <-
           [
             current_user: current_user,
             question_attrs: attrs,
             preset_params: preset_params,
             boundary: boundary,
             to_circles: final_to_circles,
             verb_grants: verb_grants,
             context_id: e(params, "context_id", nil)
           ],
         {:ok, published} <- Questions.create(opts) do
      published =
        published
        |> repo().maybe_preload([:post_content])

      # No auto-redirect: the question's permalink is a generic Discussion
      # thread that can't render polls. Offer a "Show" link in the flash instead.
      permalink = path(published)

      {
        :noreply,
        socket
        |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
        |> assign_flash(
          :info,
          "<span>#{l("Posted!")}</span> <a href='#{permalink}' target='_top' class='ml-2 link link-hover font-medium text-primary'>#{l("Show")} →</a>"
        )
      }
    else
      e ->
        error(e, "Could not create your poll")

        {
          :noreply,
          socket
          |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
          |> assign_error(l("Could not create your poll"))
        }
    end
  end

  # Composer form is `as: :post` (mirroring the post composer), so unwrap once.
  def handle_event("create_poll", %{"post" => post_params} = params, socket) do
    handle_event("create_poll", Map.merge(params, post_params) |> Map.drop(["post"]), socket)
  end

  def handle_event("create_poll", params, socket) do
    preset_params = preset_params_from_form(params)

    attrs =
      params
      |> Map.drop(["upload_metadata" | preset_form_keys()])
      |> input_to_atoms(also_discard_unknown_nested_keys: false)

    current_user = current_user_required!(socket)

    # the files uploaded in the composer, each one the question or an option places as `upload:<ref>` getting its stored URL there
    case live_upload_files_into(attrs, current_user, params["upload_metadata"], socket,
           body_paths: [[:post_content, :html_body], [:choices, :each, :name]]
         ) do
      {:error, message} ->
        # a file failed to upload: no poll is created, the text and the files stay
        {:noreply,
         socket
         |> Bonfire.UI.Common.SmartInput.LiveHandler.refused()
         |> assign_error(l("Could not create your poll") <> ": " <> message)}

      {attrs, uploaded_media} ->
        create_poll(params, attrs, uploaded_media, preset_params, current_user, socket)
    end
  end

  # Composer state events (Layer 1/2/3, see .claude/DESIGN.md) — pushed via
  # `send_update` so the dispatch site (LiveView vs container) doesn't matter.
  @composer_id "smart_input_component"

  def handle_event("select_preset", %{"preset" => "custom"}, socket) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      selected_preset: :custom,
      tuning_state: Presets.tuning_defaults(:custom),
      proposal_duration_hours: Presets.default_proposal_hours(),
      weighting: 1,
      multiple_choice: false
    })

    {:noreply, socket}
  end

  def handle_event("select_preset", %{"preset" => preset_str}, socket) do
    preset = Presets.get(preset_str)

    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      selected_preset: preset.key,
      tuning_state: preset.tuning_defaults,
      duration_hours: preset.duration_hours,
      proposal_duration_hours: Presets.default_proposal_hours(),
      weighting: preset.weighting,
      multiple_choice: false
    })

    {:noreply, socket}
  end

  def handle_event("toggle_multiple", %{"current" => current_str}, socket) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      multiple_choice: !parse_bool(current_str)
    })

    {:noreply, socket}
  end

  def handle_event("toggle_tuning", %{"key" => key, "current" => current_str}, socket) do
    # Component's `update/2` merges this partial into `tuning_state`.
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      merge_tuning: %{safe_tuning_key(key) => !parse_bool(current_str)}
    })

    {:noreply, socket}
  end

  def handle_event("change_duration", %{"duration_hours" => hours}, socket) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      duration_hours: Types.maybe_to_integer(hours, 24)
    })

    {:noreply, socket}
  end

  def handle_event(
        "change_proposal_duration",
        %{"proposal_duration_hours" => hours},
        socket
      ) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      proposal_duration_hours: Types.maybe_to_integer(hours, Presets.default_proposal_hours())
    })

    {:noreply, socket}
  end

  def handle_event("add_option", %{"current" => current_str}, socket) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      visible_option_count: Types.maybe_to_integer(current_str, 2) + 1
    })

    {:noreply, socket}
  end

  def handle_event("remove_option", %{"current" => current_str}, socket) do
    maybe_send_update(Bonfire.Poll.Web.CreatePollLive, @composer_id, %{
      visible_option_count: max(Types.maybe_to_integer(current_str, 3) - 1, 2)
    })

    {:noreply, socket}
  end

  # Resolve a form-submitted tuning key string to its canonical atom without
  # letting arbitrary atoms in via `String.to_atom/1`.
  defp safe_tuning_key(key) do
    keys = Presets.tuning_keys()
    Enum.find(keys, List.first(keys), fn k -> Atom.to_string(k) == to_string(key) end)
  end

  # Each option's attrs get the uploaded files its name shows (see `Bonfire.Files.InlineMedia.placed/2`), to attach to its choice; the others are the question's. Shown where they're attached, so the question's attachment list doesn't show an option's image again.
  defp media_to_choices(%{choices: choices} = attrs, media)
       when is_map(choices) and media != [] do
    {choices, in_choices} =
      Enum.map_reduce(choices, [], fn {key, choice}, in_choices ->
        name = if is_map(choice), do: choice[:name] || choice["name"]

        case maybe_apply(Bonfire.Files.InlineMedia, :placed, [media, name], fallback_return: []) do
          [] -> {{key, choice}, in_choices}
          shown -> {{key, Map.put(choice, :uploaded_media, shown)}, in_choices ++ shown}
        end
      end)

    {Map.put(attrs, :choices, Map.new(choices)), media -- in_choices}
  end

  defp media_to_choices(attrs, media), do: {attrs, media}

  @doc """
  Map each rendered form shape to a `[%{choice_id, weight}]` list:

    * weighted_multiple → `votes` indexed map `%{"N" => %{"choice_id"=>..., "weight"=>...}}`
    * single → `vote` is a choice_id string
    * multiple → `vote` is a `%{choice_id => "1"}` map
  """
  def parse_votes(%{"votes" => votes}) when is_map(votes) do
    for {_idx, %{"choice_id" => cid} = entry} <- votes do
      # Empty string is truthy in Elixir, so `|| 1` wouldn't catch a blank weight.
      %{choice_id: cid, weight: if(entry["weight"] in [nil, ""], do: 1, else: entry["weight"])}
    end
  end

  def parse_votes(%{"vote" => choice_id}) when is_binary(choice_id),
    do: [%{choice_id: choice_id, weight: 1}]

  def parse_votes(%{"vote" => votes}) when is_map(votes) do
    for {choice_id, weight} <- votes, do: %{choice_id: choice_id, weight: weight}
  end

  def parse_votes(_), do: []
end
