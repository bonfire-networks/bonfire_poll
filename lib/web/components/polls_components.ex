defmodule Bonfire.Poll.EditProposalLive do
  @moduledoc "A single option row (name input + delete button) in the composer."
  use Bonfire.UI.Common.Web, :stateless_component

  prop index, :integer, default: 0
  prop proposal, :any, default: %{}
  prop event_target, :any, default: "#smart_input"
  prop visible_option_count, :integer, default: 2

  def render(assigns) do
    ~F"""
    <div class="flex items-center gap-2">
      {!-- phx-update=ignore preserves the typed value across morphdom passes. --}
      <div id={"poll_option_wrapper_#{@index}"} phx-update="ignore" class="flex-1">
        <label for={"poll_option_#{@index}"} class="sr-only">
          {l("Option %{n}", n: @index + 1)}
        </label>
        {!-- No `value=` on this input: LV's text-input tracking would re-emit
             it on re-render and clobber the user-typed DOM value, even with
             `phx-update="ignore"` on the wrapper. --}
        <input
          id={"poll_option_#{@index}"}
          name={"choices[#{@index}][name]"}
          type="text"
          placeholder={l("Option %{n}", n: @index + 1)}
          class="block w-full rounded-md border border-base-content/20 bg-base-100 px-3 py-2.5 text-sm text-base-content placeholder:text-base-content/50 focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary/40"
        />
      </div>
      <button
        :if={@visible_option_count > 2}
        type="button"
        phx-click="Bonfire.Poll:remove_option"
        phx-value-index={@index}
        phx-value-current={@visible_option_count}
        phx-target={@event_target}
        data-role="remove-option"
        aria-label={l("Remove option %{n}", n: @index + 1)}
        class="inline-flex h-11 w-11 items-center justify-center rounded-md border border-base-content/15 text-base-content/60 hover:border-error/40 hover:bg-error/5 hover:text-error focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
      >
        <#Icon iconify="ph:trash-duotone" class="h-4 w-4" />
      </button>
    </div>
    """
  end
end

defmodule Bonfire.Poll.QuestionTimeLabelLive do
  @moduledoc "Localised time label for a poll phase."
  use Bonfire.UI.Common.Web, :stateless_component

  def phases do
    %{
      "proposal" => l("Proposal Phase"),
      "voting" => l("Voting Phase")
    }
  end

  def render(assigns) do
    ~F"""
    <question-time-label data-start={@start_date}>
      <span>{phases()[@phase]}:&nbsp;</span>

      {#if @current_time < @start_date}
        <br>
        <span>{l("Starts")}:&nbsp;</span>
        <span id="start-date" class="link-success">{@start_date}</span>
        <br>
        <span>{l("Lasts for")}:&nbsp;</span>
        <div class="badge badge-success">{@dates}</div>
      {#elseif @current_time < List.first(@dates)}
        <div class="badge badge-error">{@dates}</div>
        <span>&nbsp;({l("remainingTime")})</span>
      {#else}
        <span class="text-info">{l("done")}</span>
      {/if}
      <br>
    </question-time-label>
    """
  end
end

defmodule Bonfire.Poll.VotingCSSLive do
  @moduledoc false
  # Pins runtime-toggled Tailwind utilities (outline-success/warning/error)
  # into the JIT scan; not rendered for its visual output.
  use Bonfire.UI.Common.Web, :stateless_component

  def render(assigns) do
    ~F"""
    <div class="outline outline-success outline-warning outline-error">
    </div>
    """
  end
end
