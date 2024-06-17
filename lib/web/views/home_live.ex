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
       nav_items: Bonfire.Common.ExtensionModule.default_nav()
     )}
  end
end
