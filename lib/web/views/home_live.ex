defmodule Bonfire.Poll.HomeLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  alias Bonfire.Poll.{Questions, Question}
  alias Bonfire.Poll.{WeightSelector, PhaseSelector}

  def mount(_params, _session, socket) do
    changeset = Question.changeset(%{})

    {:ok,
     assign(socket,
       create_object_type: :page,
       smart_input_opts: %{wysiwyg: false, prompt: l("Create a poll")},
       changeset: changeset,
       form: to_form(changeset),
       page: "Poll",
       page_title: "Poll",
       back: true,
       proposals: [],
       nav_items: Bonfire.Common.ExtensionModule.default_nav(),
       without_sidebar: true,
       without_secondary_widgets: true,
       smart_input_opts: [
         #  create_object_type: maybe_to_atom(e(session, "create_object_type", nil)),
         inline_only: true,
         hide_buttons: true
         #  text: e(session, "smart_input_text", nil)
       ]
     )}
  end
end
